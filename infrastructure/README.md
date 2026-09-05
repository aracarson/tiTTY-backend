# EC2 instance template

// MARK: - Task list

- [x] Provision an ARM64 Graviton EC2 instance
- [x] Expose public TCP 443 only
- [x] Disable public SSH, HTTP and Axum access
- [x] Enable AWS Systems Manager administration
- [x] Encrypt the EBS root volume
- [x] Require Instance Metadata Service v2
- [x] Add optional least-privilege S3 backup access

This package adds `infrastructure/ec2-cloudformation.yaml` to the HTTPS-only tiTTY backend patch.

## What it creates

```text
CloudFormation stack
├── t4g.micro ARM64 EC2 instance
├── encrypted gp3 EBS root volume
├── Elastic IP
├── security group allowing inbound TCP 443 only
├── instance role with AmazonSSMManagedInstanceCore
├── optional S3 backup-prefix permissions
└── launch template with HTTPS-only host firewall bootstrap
```

The instance has no EC2 key pair and the security group has no SSH rule. Administration uses AWS Systems Manager Session Manager.

## Prerequisites

- An existing VPC
- A public subnet with a route to an Internet gateway
- AWS CLI credentials permitted to create CloudFormation, EC2, IAM and security-group resources
- An optional existing private S3 bucket for backups

## Deploy

Copy the example parameters and replace the placeholders:

```bash
cp infrastructure/parameters.example.json infrastructure/parameters.json
```

Deploy in Toronto's AWS region by default:

```bash
AWS_REGION=ca-central-1 \
./scripts/deploy-ec2-template.sh \
  titty-backend \
  infrastructure/parameters.json
```

After deployment:

1. Create an A record such as `iden.titty.app` using the output Elastic IP.
2. Connect with Systems Manager.
3. Install the HTTPS-only Caddy configuration from the main backend patch.
4. Deploy the Rust service.
5. Confirm ports 22, 80 and 8080 are unreachable publicly.

## Important certificate note

The Caddy configuration uses HTTPS only and does not listen on port 80. Certificate issuance therefore requires a validation method that works through port 443, or a DNS challenge configuration. Confirm certificate issuance before relying on the endpoint in production.

## Scope

The template provisions infrastructure but does not clone a private repository, inject a JWT secret, or deploy the production binary. Secrets should be placed through Systems Manager Parameter Store, Secrets Manager, or the protected environment file after provisioning. Do not put secrets into CloudFormation parameters or EC2 user data.
