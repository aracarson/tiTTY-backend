# HTTPS-only production patch

// MARK: - Task list

- [x] Remove GraphiQL from the Axum application
- [x] Restrict GraphQL to POST `/graphql`
- [x] Require Axum to bind to loopback
- [x] Configure Caddy without an HTTP redirect listener
- [x] Block inbound TCP 22, 80 and 8080 at the host firewall
- [x] Permit inbound TCP 443 only

Overlay this patch onto the existing `tiTTY-backend` repository.

Before applying the firewall:

1. Attach an EC2 IAM role with `AmazonSSMManagedInstanceCore`.
2. Confirm the instance is accessible through AWS Systems Manager Session Manager.
3. Configure the EC2 security group to allow only inbound TCP 443.
4. Point the identity DNS record at the instance.

Then run:

```bash
sudo ./scripts/bootstrap-https-only.sh
sudo ./scripts/install-caddy.sh identity.example.com
sudo ./scripts/deploy.sh
```

The public endpoints are:

```text
POST https://identity.example.com/graphql
GET  https://identity.example.com/healthz
```

There is no GraphiQL route. Port 8080 remains loopback-only. Public HTTP and public SSH are disabled.
