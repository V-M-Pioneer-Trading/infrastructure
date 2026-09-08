# navigation-service

Terraform stack for navigation-service on ECS Fargate with persistent SQLite data on EFS.

## What this stack creates

- ECS cluster, task definition, and service
- EFS file system + access point mounted at `/data`
- IAM execution/task roles
- CloudWatch log group
- Security groups for app traffic and NFS

## Runtime env wiring

Container gets:

- `SQLITE_DB_PATH` (default `/data/nav.db`)
- `SPRING_PROFILES_ACTIVE` (`dev`/`prod`)
- `SERVER_PORT` (from `container_port`)

Spring config can use:

```yaml
spring:
  datasource:
    url: jdbc:sqlite:${SQLITE_DB_PATH:/data/nav.db}
```

## Usage

```bash
cd projects/navigation-service
cp dev.tfvars.example dev.tfvars
terraform init -backend-config="bucket=<your-tfstate-bucket>"
terraform plan -var-file=dev.tfvars
terraform apply -var-file=dev.tfvars
```

