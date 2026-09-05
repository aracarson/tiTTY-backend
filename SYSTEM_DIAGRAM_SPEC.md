# tiTTY Backend System Diagram Specification

## Purpose

Create a clear architecture and request-flow diagram for the tiTTY identiTTY identity backend. The diagram should show the public request path, the private application and database boundary, authentication data flow, AWS operational services, and deployment/backup paths.

The system is a low-resource identity registry. It stores public identity data only: an identiTTY, an AccountID derived from an Ed25519 public key, the public key, timestamps, and short-lived authentication challenges.

## Primary deployment

- AWS Region: `ca-central-1`
- One ARM64 Graviton EC2 instance, currently a `t4g.micro` class host
- Amazon Linux 2023
- Encrypted EBS root volume
- Public Elastic IP and DNS name: `iden.titty.app`
- No public SSH administration; administration uses AWS Systems Manager Session Manager
- EC2 security group should allow inbound TCP `443` only
- The instance requires IMDSv2

## Main architecture components

### Client

External client applications use HTTPS and GraphQL. A client owns an Ed25519 key pair. The private key remains with the client and is never sent to or stored by the backend.

### DNS and certificate automation

- Route 53 resolves `iden.titty.app` to the EC2 Elastic IP.
- Caddy uses a Route 53 DNS challenge to obtain and renew the TLS certificate from Let's Encrypt.
- The Caddy process needs narrowly scoped Route 53 permissions for the ACME DNS records.
- DNS validation means inbound TCP `80` is not required.

### Caddy reverse proxy

- Public listener: TCP `443`
- Terminates TLS for `iden.titty.app`
- Supports HTTP/1.1, HTTP/2, and HTTP/3
- Applies compression and security headers
- Limits request bodies to 64 KB
- Proxies requests to `127.0.0.1:8080`
- Caddy's admin API remains local-only

### Rust Axum and async-graphql service

- Binary: `/opt/titty-backend/bin/titty-backend`
- Systemd unit: `titty-backend.service`
- Runs as the unprivileged `titty-backend` user
- Binds only to `127.0.0.1:8080`
- Public routes:
  - `GET /healthz`
  - `POST /graphql`
- Middleware includes request IDs, request tracing, CORS, and a 64 KB body limit
- CORS allows one configured origin through `TITTY_ALLOWED_ORIGIN`
- GraphiQL is not exposed by the production service

### SQLite database

- Database path: `/var/lib/titty-backend/identity.db`
- Stored on local encrypted EBS, not directly on S3
- SQLx connection pool is bounded to four connections
- Foreign keys are enabled
- Busy timeout is five seconds
- WAL journaling is enabled
- `synchronous = FULL`
- `secure_delete = ON`
- Migrations run automatically at service startup

### Scheduled backup

- `titty-backend-backup.timer` runs daily at `03:15 UTC` with a randomized delay
- `titty-backend-backup.service` runs as the `titty-backend` user
- The backup uses SQLite's online backup operation to create a consistent snapshot
- The snapshot is uploaded to a private S3 bucket and prefix
- The EC2 instance role should grant only the required S3 backup permissions

### AWS operations

- AWS Systems Manager Agent runs on the EC2 instance
- Operators use `aws ssm start-session` for shell access
- The EC2 instance role provides SSM, backup, and certificate automation permissions
- No SSH key pair is required
- CloudFormation provisions the instance, IAM role/profile, security group, EBS volume, launch template, and Elastic IP

## GraphQL API surface

### Queries

- `isIdentiTTYAvailable(identiTTY)` checks normalized identiTTY availability.
- `account(identiTTY)` looks up an identity by normalized identiTTY.
- `accountByID(accountID)` looks up an identity by AccountID.
- `me` returns the identity represented by the validated JWT and requires a bearer token.

### Mutations

- `registerAccount(input)` registers an account identity.
- `requestChallenge(accountID)` creates a random challenge for a known account.
- `authenticate(input)` verifies the signed challenge and returns a short-lived JWT session.

The identity discovery, registration, challenge, and authentication operations are public but rate-limited. The `me` resolver is authenticated and receives the account subject from validated JWT context.

## Request flows

### Registration flow

1. Client sends `registerAccount` over HTTPS to Caddy.
2. Caddy terminates TLS and proxies the GraphQL request to `127.0.0.1:8080`.
3. The service normalizes the identiTTY.
4. The service Base64-decodes the public key and requires exactly 32 bytes.
5. The service derives `AccountID` as `acct_` plus the lowercase SHA-256 hex digest of the public key.
6. The derived AccountID must match the submitted AccountID.
7. SQLite inserts the account atomically.
8. Unique constraints reject duplicate identiTTY, AccountID, or public key values.
9. The service returns the public identity record. No private key is received or stored.

### Challenge request flow

1. Client sends `requestChallenge(accountID)` over HTTPS.
2. The service verifies that the account exists.
3. The service generates a cryptographically random 32-byte challenge.
4. The service stores the challenge with a UUID and expiry, normally 180 seconds.
5. The service returns the challenge and expiry to the client.

### Authentication flow

1. Client signs the raw challenge bytes with its Ed25519 private key.
2. Client sends `authenticate(accountID, challengeID, signature)` over HTTPS.
3. The service loads the unused challenge and the registered public key in a SQLite transaction.
4. The service rejects missing, mismatched, expired, or already-used challenges.
5. The service verifies the Ed25519 signature.
6. The service marks the challenge used before issuing a session.
7. The service commits the transaction.
8. The service returns a short-lived HMAC-signed JWT containing the account subject, issuer, issued-at time, and expiry. The default session lifetime is 3600 seconds.

### Health flow

1. A monitoring client sends `GET https://iden.titty.app/healthz`.
2. Caddy proxies the request to the private Axum health route.
3. The service returns HTTP 200 with `ok` when the process is responsive.
4. Operational checks separately verify systemd, EC2 status checks, SSM online status, disk space, memory, and backup timer state.

### Backup flow

1. The systemd timer starts the backup service.
2. The backup service creates a consistent SQLite snapshot from the live database.
3. The snapshot is uploaded to the private S3 backup prefix using the EC2 instance role.
4. The service exits and systemd records success or failure in the journal.

### Deployment and administration flow

1. Operator runs `aws login` and selects/configures the `ca-central-1` region.
2. Operator queries EC2 to obtain the running instance ID by the `titty-backend` Name tag.
3. Operator checks EC2 system and instance status checks.
4. Operator checks SSM registration and starts a Session Manager shell.
5. Operator uploads or installs the ARM64 backend binary and restarts `titty-backend.service`.
6. Operator checks Caddy, the backend service, local health, public health, and journal logs.

## Data model

### `accounts`

- `account_id`: primary key, text
- `identiTTY`: case-insensitive unique text
- `public_key`: unique 32-byte blob
- `created_at`: RFC3339 timestamp

### `authentication_challenges`

- `challenge_id`: primary key UUID
- `account_id`: foreign key to `accounts`
- `challenge`: random 32-byte blob
- `expires_at`: timestamp
- `used_at`: nullable timestamp
- `created_at`: timestamp
- Expired and used challenges are removed during service startup.

## Trust boundaries and security controls

Show these boundaries explicitly in the diagram:

1. Public internet to AWS network edge: only HTTPS `443` is exposed.
2. Caddy to Axum: local loopback only; the application is not directly internet-facing.
3. Axum to SQLite: local filesystem on encrypted EBS.
4. EC2 to AWS services: instance-profile credentials, no long-lived application credentials.
5. Client private key to backend: it must never cross the boundary.
6. Backup path: SQLite snapshot to private S3, protected by least-privilege IAM.
7. Administration path: operator to SSM, with no public SSH.

## Diagram deliverables

Produce:

1. A deployment/component diagram showing Client, Route 53, Let's Encrypt, Internet, security group, EC2, Caddy, Axum/GraphQL, SQLite/EBS, systemd, SSM, and S3.
2. A registration sequence diagram.
3. An authentication sequence diagram showing challenge creation, client signing, signature verification, single-use consumption, and JWT issuance.
4. A backup/deployment operations diagram showing systemd timer, S3, SSM, and binary replacement.
5. A compact legend identifying public, private-loopback, filesystem, AWS-control-plane, and credential/data-flow boundaries.

## Diagram constraints

- Label Caddy as the only public application ingress.
- Label Axum as `127.0.0.1:8080` and mark it private.
- Show TCP `443` as the only inbound security-group rule.
- Do not show SSH as an administration path.
- Do not imply that the private Ed25519 key is stored in AWS or sent to the backend.
- Distinguish the Route 53 DNS challenge from HTTP-01 validation; the deployed design uses DNS validation and does not require port `80`.
- Do not put JWT secrets, AWS access keys, or other secret values in the diagram.
- Show S3 as backup storage, not as the live SQLite database.
- Mark health checks as liveness checks unless a deeper database readiness check is explicitly added later.

## Future enhancements to mark as optional

- Edge rate limiting for registration, challenge requests, and failed authentication.
- CloudTrail and alarms for IAM, security-group, EC2, and Route 53 changes.
- S3 versioning, encryption, lifecycle retention, and restore testing.
- Migration from temporary IAM-user credentials to a least-privilege EC2 instance role for Caddy Route 53 access.
- Token revocation or shorter JWT lifetimes for high-impact operations.
- Multi-device identity recovery.
