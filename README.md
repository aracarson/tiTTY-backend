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

### Updating the deployed binary

Build and extract the ARM64 binary on the development machine, then upload it to the instance through your normal S3 and SSM workflow. Copy the updater script to the instance once:

```bash
sudo install -o root -g root -m 0755 scripts/update-binary.sh /opt/titty-backend/update-binary.sh
```

After uploading a new binary to `/tmp/titty-backend`, run this in the SSM session:

```bash
sudo bash /opt/titty-backend/update-binary.sh /tmp/titty-backend
```

The updater saves a timestamped rollback copy, installs the binary atomically, restarts `titty-backend.service`, checks the service and local `/healthz` endpoint, and restores the previous binary if the restart or health check fails. It expects the uploaded binary to target the instance architecture: Linux ARM64 (`aarch64`).

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

## Identity API security

The public GraphQL operations are:

- `isIdentiTTYAvailable`, `account` and `accountByID` for public identity discovery
- `registerAccount` for public-key registration
- `requestChallenge` and `authenticate` for the challenge login flow

The `me` query requires an `Authorization: Bearer <JWT>` header. The service validates the JWT signature, issuer and expiry before making the authenticated account available to resolvers.

Registration, challenge requests and authentication attempts have per-client rate limits, and the GraphQL endpoint has a global per-client request limit. These limits are process-local and reset when the service restarts; use a shared edge limiter or distributed store when running multiple instances.

The client private Ed25519 key never crosses the API boundary. The client signs the server-provided challenge locally, and the backend verifies the signature against the stored public key.

## Structured API access logging

The Rust service writes one JSON access event per HTTP request to daily-rotated files under `/var/log/titty-backend/`. Each event contains the method, endpoint, status, latency, and request ID. Request headers, bodies, JWTs, public keys, AccountIDs, and identiTTY values are not written.

Install the logging cleanup service on the EC2 host after deploying a binary that includes the logging layer:

```bash
sudo install -o root -g root -m 0755 /tmp/install-api-logging.sh /tmp/cull-api-logs.sh
sudo install -o root -g root -m 0644 /tmp/titty-backend-api-log-cull.service /tmp/titty-backend-api-log-cull.timer
sudo bash /tmp/install-api-logging.sh
```

The installer creates `/var/log/titty-backend/`, installs `titty-backend-api-log-cull.timer`, and restarts the backend. Rotated files older than 14 days are removed daily. Override the directory with `TITTY_API_LOG_DIR` and retention with `TITTY_API_LOG_RETENTION_DAYS` in the systemd environment file before restarting the service and cleanup timer.

Inspect the logs with:

```bash
sudo ls -lh /var/log/titty-backend/
sudo journalctl -u titty-backend-api-log-cull.service --no-pager
sudo systemctl list-timers titty-backend-api-log-cull.timer
```

## Security oversight and metrics

Install the reporting scripts on the EC2 host:

```bash
sudo install -o root -g root -m 0755 scripts/generate-metrics.sh /opt/titty-backend/bin/generate-metrics.sh
sudo install -o root -g root -m 0755 scripts/generate-security-report.sh /opt/titty-backend/bin/generate-security-report.sh
sudo install -o root -g root -m 0755 scripts/install-security-logging.sh /opt/titty-backend/bin/install-security-logging.sh
sudo bash /opt/titty-backend/bin/install-security-logging.sh
```

Generate aggregate registration metrics. The report does not include identiTTY values, AccountIDs, public keys, or JWTs:

```bash
sudo bash /opt/titty-backend/bin/generate-metrics.sh
```

Reports are written under `/var/lib/titty-backend/metrics/` and uploaded by default to `s3://identitty/reports/metrics/<timestamp>/`; set `TITTY_REPORTS_S3_URI` to override the destination. The newest local report is available at `metrics/latest/index.html`. Copy the HTML and CSV files to an operator workstation before opening them. Do not serve this directory through Caddy.

Generate an operational security report:

```bash
sudo bash /opt/titty-backend/bin/generate-security-report.sh
```

Reports are written with mode `0600` under `/var/lib/titty-backend/security-reports/` and uploaded by default to `s3://identitty/reports/security-reports/`; set `TITTY_REPORTS_S3_URI` to override the destination. They include recent SSM and login activity, failed systemd units, critical service status, package history, listening sockets, and host resource state. They do not contain application secrets by design. Local report files older than 14 days are deleted only after the S3 upload succeeds; S3 retention is controlled separately by the bucket lifecycle policy.

The EC2 instance role must allow `s3:PutObject` on both report prefixes in addition to the database backup prefix. Set `TITTY_REPORTS_S3_URI` if you want reports in a different bucket or prefix; otherwise the scripts use `s3://identitty/reports`.

For deeper privileged-command auditing, install and enable auditd, then review reports carefully because audit logs can contain sensitive command arguments:

```bash
sudo dnf install -y audit
sudo systemctl enable --now auditd
```

Also retain AWS CloudTrail for IAM, EC2, security-group, S3, and Route 53 changes. Host reports and application journald logs are complementary to CloudTrail, not a replacement for it.

Generate API call metrics from the backend's aggregate SQLite request counters. The default window is the last 24 hours; pass a time expression to change it:

```bash
sudo install -o root -g root -m 0755 scripts/generate-api-metrics.sh /opt/titty-backend/bin/generate-api-metrics.sh
sudo bash /opt/titty-backend/bin/generate-api-metrics.sh
sudo bash /opt/titty-backend/bin/generate-api-metrics.sh "7 days ago"
```

The backend records `/graphql` and `/healthz` calls directly into the `api_request_metrics` table in 15-minute UTC buckets, grouped by method, endpoint, and status class. The report writes an HTML histogram, CSV data, and a JSON summary. It uploads to `s3://identitty/reports/api/<timestamp>/` by default and removes local report directories older than 14 days only after the upload succeeds. The EC2 role needs `s3:PutObject` for `arn:aws:s3:::identitty/reports/api/*`.

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