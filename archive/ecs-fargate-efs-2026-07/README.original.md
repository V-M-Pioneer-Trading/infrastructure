# V-M-Pioneer-Trading infrastructure

Terraform code for V-M-Pioneer-Trading services.

## Layout

```
modules/
  ecs-service-with-efs/      Reusable ECS Fargate + EFS module (persistent SQLite storage)
projects/
  navigation-service/        Deployed stack for navigation-service
.github/workflows/
  plan.yml                   CI validate + plan for Terraform stacks
```

## Quick start (navigation-service)

```bash
cd projects/navigation-service
cp dev.tfvars.example dev.tfvars
terraform init -backend-config="bucket=<your-tfstate-bucket>"
terraform plan -var-file=dev.tfvars
```

