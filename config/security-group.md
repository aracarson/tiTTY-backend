# EC2 security group

// MARK: - Task list

- [x] Allow public HTTPS only
- [x] Keep Axum private
- [x] Use AWS Systems Manager instead of public SSH

Use exactly one inbound rule:

```text
HTTPS | TCP | 443 | 0.0.0.0/0
HTTPS | TCP | 443 | ::/0, only if IPv6 is enabled
```

Do not add inbound rules for TCP 22, 80 or 8080.

Attach `AmazonSSMManagedInstanceCore` to the EC2 instance role and confirm Session Manager works before applying the host firewall. Keep outbound TCP 443 available for Systems Manager, certificate issuance, package repositories and S3 backups.

The instance setup script cannot safely alter the AWS security group without EC2 control-plane permissions. Do not grant those permissions merely for setup automation. Configure the security group separately in AWS.
