# tiTTY-backend

Low-resource identiTTY identity registry implemented with Rust, Axum, async-graphql and SQLite.

## // MARK: - Task list

- [x] Enforce globally unique identiTTY values
- [x] Derive and verify AccountID from the Ed25519 public key
- [x] Store public identity only
- [x] Generate random, short-lived, single-use authentication challenges
- [x] Verify challenge signatures
- [x] Issue short-lived JWT sessions
- [x] Run as a hardened systemd service
- [x] Create consistent SQLite backups for S3
- [ ] Add edge rate limiting before public launch
- [ ] Add recovery and multi-device support later

## Repository layout

```text
tiTTY-backend/
├── src/                       Rust service
├── graphql/                   Schema and sample operations
├── migrations/                SQLite schema
├── data/identity.db           Empty initial SQLite database
├── systemd/                   Service and backup timer units
├── scripts/                   EC2 bootstrap, deployment and backup
├── config/Caddyfile.example   HTTPS reverse proxy example
├── Cargo.toml
└── .env.example
```

## Security model

The service stores `identiTTY`, `AccountID`, public key and timestamps. It never receives or stores a private key. The server recomputes `AccountID` as `acct_` plus the lowercase SHA-256 hex digest of the 32-byte Ed25519 public key.

Public keys, signatures and challenges are Base64 in GraphQL. Each challenge is 32 random bytes, expires quickly, and is consumed exactly once. The authentication transaction marks the challenge used before issuing the session.

## Local development

```bash
./scripts/init-local.sh
cargo run
```

Endpoints:

```text
GraphQL: http://127.0.0.1:8080/graphql
GraphiQL: http://127.0.0.1:8080/graphiql
Health:  http://127.0.0.1:8080/healthz
```

GraphiQL should be disabled or access-restricted before a production launch if you do not want interactive schema exploration.

## EC2 deployment

Recommended starting point: Amazon Linux 2023 ARM64 on a t4g.micro or smaller supported Graviton instance, with an encrypted EBS root volume. SQLite must live on the local EBS filesystem, not directly on S3.

```bash
sudo ./scripts/bootstrap-ec2.sh
sudo mkdir -p /opt/titty-backend/source
sudo cp -R . /opt/titty-backend/source/
cd /opt/titty-backend/source
sudo ./scripts/deploy.sh
```

The first deployment intentionally stops after creating:

```text
/etc/titty-backend/titty-backend.env
```

Edit it, set a strong JWT secret and the permitted origin, then rerun `deploy.sh`.

## HTTPS

The Rust process binds to `127.0.0.1:8080` by default. Put Caddy, nginx, or an AWS Application Load Balancer in front of it for TLS. `config/Caddyfile.example` shows the simple Caddy route.

Do not expose port 8080 publicly. The EC2 security group should normally allow:

```text
22/tcp  only from your administration IP, or use SSM instead
80/tcp  public when using automatic HTTPS certificate issuance
443/tcp public
```

## S3 backup

Set this in `/etc/titty-backend/titty-backend.env`:

```bash
TITTY_DATABASE_PATH=/var/lib/titty-backend/identity.db
TITTY_BACKUP_S3_URI=s3://your-private-bucket/titty-backend
```

Attach an EC2 IAM role that can write only to the required bucket prefix. Then run:

```bash
sudo ./scripts/install-backup-timer.sh
```

The backup script uses SQLite's `.backup` operation so that the uploaded snapshot is consistent even when WAL mode is active. Enable S3 versioning, default encryption and lifecycle retention on the bucket.

## Required IAM permissions

A least-privilege instance role can use the policy in `config/s3-backup-policy.json`. Replace the bucket and prefix placeholders.

## Important production work

Before public registration, add request throttling at Caddy, nginx, AWS WAF, or an ALB. In particular, throttle `registerAccount`, `requestChallenge`, and failed `authenticate` operations by source IP and account. Keep application error messages generic. Monitor disk usage, backup success and authentication failure volume.

The included HMAC-signed JWT is an initial authenticated session mechanism. Add token revocation or reduce token lifetime before using sessions for high-impact account changes.


#### Connection info

Log in with the AWS CLI:

```bash
aws login
```

Set the deployment region if it is not already configured:

```bash
aws configure set region ca-central-1
```

Verify the active AWS account:

```bash
aws sts get-caller-identity
```

Find the running EC2 instance ID:

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
	--region ca-central-1 \
	--filters "Name=tag:Name,Values=titty-backend" "Name=instance-state-name,Values=running" \
	--query 'Reservations[0].Instances[0].InstanceId' \
	--output text)

echo "$INSTANCE_ID"
```

Check EC2 system and instance health:

```bash
aws ec2 describe-instance-status \
	--region ca-central-1 \
	--instance-ids "$INSTANCE_ID" \
	--include-all-instances \
	--query 'InstanceStatuses[0].[InstanceState.Name,SystemStatus.Status,InstanceStatus.Status]' \
	--output table
```

Check that the instance is registered and online in Systems Manager:

```bash
aws ssm describe-instance-information \
	--region ca-central-1 \
	--filters "Key=InstanceIds,Values=$INSTANCE_ID" \
	--query 'InstanceInformationList[0].[InstanceId,PingStatus,AgentVersion,PlatformName]' \
	--output table
```

Start an interactive Session Manager shell:

```bash
aws ssm start-session \
	--target "$INSTANCE_ID" \
	--region ca-central-1
```

Inside the SSM session, check the services and local application health:

```bash
sudo systemctl --no-pager --full status caddy
sudo systemctl --no-pager --full status titty-backend
curl -fsS http://127.0.0.1:8080/healthz
```

From your local terminal, check the public HTTPS endpoint:

```bash
curl -fsS https://iden.titty.app/healthz
```