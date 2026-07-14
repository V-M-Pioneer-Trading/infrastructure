# infrastructure

Terraform for navigation-service infrastructure in `V-M-Pioneer-Trading/infrastructure`.

## What this stack does

- Reads shared EC2 state from personal infra remote state at `personal/terraform.tfstate`.
- Reuses outputs `ec2_instance_ip` and `ec2_security_group_id`.
- Adds navigation-service ingress on port `8080` to shared EC2 security group.
- Exposes deployment-friendly outputs for EC2 IP and service base URL.

This repo no longer manages dedicated ECS or EFS resources for navigation-service.

## Inputs

- `state_bucket`: S3 bucket that stores Terraform state.
- `aws_region`: AWS region for both this stack and remote-state lookup. Default: `eu-central-1`.
- `navigation_service_port`: navigation-service port. Default: `8080`.

## Commands

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```
