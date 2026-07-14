# infrastructure

Terraform for navigation-service infrastructure in `V-M-Pioneer-Trading/infrastructure`.

## What this stack does

- Reads shared EC2 state from personal infra remote state at `personal/terraform.tfstate`.
- Reuses outputs `ec2_instance_ip` and `ec2_security_group_id`.
- Adds navigation-service ingress on port `8080` to shared EC2 security group.
- Creates encrypted EBS data volume and attaches it to shared EC2 host.
- Boots navigation-service directly on shared EC2 instance with AWS SSM.
- Exposes deployment-friendly outputs for EC2 IP and service base URL.

This repo no longer manages dedicated ECS or EFS resources for navigation-service.

SQLite is local to EC2 host at `/data/nav.db` and not decoupled into managed database.
`/data` is mounted from separate encrypted EBS volume (not root disk) for better durability.

## Inputs

- `state_bucket`: S3 bucket that stores Terraform state.
- `ec2_instance_id`: Shared EC2 instance ID targeted by SSM bootstrap command.
- `aws_region`: AWS region for both this stack and remote-state lookup. Default: `eu-central-1`.
- `navigation_service_port`: navigation-service port. Default: `8080`.
- `navigation_service_image`: container image and tag for navigation-service. Default: `ghcr.io/v-m-pioneer-trading/navigation-service:latest`.
- `navigation_service_data_volume_size_gb`: encrypted EBS size for `/data`. Default: `10`.

## Startup model on EC2

Terraform creates encrypted standalone EBS volume, attaches it to `ec2_instance_id`, then creates an SSM Command document + association. The association runs shell commands on host to:

1. Wait for attached EBS device (`/dev/disk/by-id/...` or `/dev/xvdf` fallback).
2. Create ext4 filesystem if volume is blank, persist mount in `/etc/fstab`, mount at `/data`.
3. Install Docker (`dnf`, `yum`, or `apt-get` path).
4. Enable and start Docker daemon.
5. Pull selected `navigation_service_image`.
6. Run container with:
   - `-p 8080:8080`
   - `-v /data:/data`
   - `-e SQLITE_DB_PATH=/data/nav.db`
   - `-e SPRING_PROFILES_ACTIVE=prod`
   - `--restart unless-stopped`

Container name is `navigation-service`.

Durability tradeoff: this stays cheap and simple (single EC2 + single EBS). If EC2 is replaced and retained EBS is reattached, SQLite data persists. There is no multi-AZ DB failover in this model.

## Commands

```bash
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

## Assumptions

- Shared EC2 instance has SSM agent available and IAM permissions for SSM command execution.
- Existing security group rule for port `8080` remains in place for external reachability via EC2 IP/base URL.
- Data volume is intentionally standalone EBS resource, so it is not tied to root disk lifecycle.
