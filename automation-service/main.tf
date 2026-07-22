provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "personal" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "personal/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "navigation_service" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "navigation-service/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "agent_service" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "agent-service/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "fleet_service" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "fleet-service/terraform.tfstate"
    region = var.aws_region
  }
}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

resource "random_password" "postgres" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "postgres_password" {
  name  = "automation-service-postgres-password"
  type  = "SecureString"
  value = random_password.postgres.result
}

# Lets the shared host's bootstrap script read this SecureString parameter at
# container-start time, mirroring agent-service's MySQL password pattern.
resource "aws_iam_role_policy" "shared_ec2_automation_service_ssm_parameters" {
  name = "automation-service-ssm-parameters"
  role = data.terraform_remote_state.personal.outputs.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.postgres_password.arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
      }
    ]
  })
}

# No dedicated ingress rule here — navigation-service's stack owns a single shared rule
# spanning ports 80-8080 (agent/fleet/navigation), and automation-service's port 3003
# already falls inside that range, so no new rule (and no further rules-per-security-group
# quota spend) is needed.

resource "aws_ebs_volume" "automation_service_postgres_data" {
  availability_zone = data.aws_instance.automation_service_host.availability_zone
  encrypted         = true
  size              = var.automation_service_postgres_data_volume_size_gb
  type              = "gp3"

  tags = {
    Backup = "automation-service-postgres-daily"
  }
}

data "aws_instance" "automation_service_host" {
  instance_id = var.ec2_instance_id
}

resource "aws_volume_attachment" "automation_service_postgres_data" {
  device_name = "/dev/xvdh"
  volume_id   = aws_ebs_volume.automation_service_postgres_data.id
  instance_id = var.ec2_instance_id
}

# ============================================================
# Daily EBS snapshots for the Postgres data volume (7-day retention)
# ============================================================

resource "aws_iam_role" "dlm_lifecycle" {
  name = "automation-service-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm_lifecycle" {
  role       = aws_iam_role.dlm_lifecycle.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "automation_service_postgres_data" {
  description        = "Daily snapshots for automation-service Postgres EBS data volume"
  execution_role_arn = aws_iam_role.dlm_lifecycle.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "automation-service-postgres-daily"
    }

    schedule {
      name = "daily-snapshot"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }

      copy_tags = true
    }
  }
}

locals {
  automation_service_bootstrap_commands = [
    "set -euo pipefail",
    "cloud-init status --wait >/dev/null 2>&1 || true",
    "DATA_DEVICE_SYMLINK=\"/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.automation_service_postgres_data.id, "-", "")}\"",
    "DATA_DEVICE=\"\"",
    "for _ in $(seq 1 30); do",
    "  if [ -e \"$DATA_DEVICE_SYMLINK\" ]; then",
    "    DATA_DEVICE=$(readlink -f \"$DATA_DEVICE_SYMLINK\")",
    "    break",
    "  fi",
    "  if [ -b /dev/xvdh ]; then",
    "    DATA_DEVICE=/dev/xvdh",
    "    break",
    "  fi",
    "  sleep 5",
    "done",
    "[ -n \"$DATA_DEVICE\" ] || { echo 'Data volume device not found.' >&2; exit 1; }",
    "if ! blkid \"$DATA_DEVICE\" >/dev/null 2>&1; then",
    "  mkfs.ext4 -F \"$DATA_DEVICE\"",
    "fi",
    "mkdir -p /data/automation-service-postgres",
    "DATA_UUID=$(blkid -s UUID -o value \"$DATA_DEVICE\")",
    "grep -q \"^UUID=$DATA_UUID /data/automation-service-postgres \" /etc/fstab || echo \"UUID=$DATA_UUID /data/automation-service-postgres ext4 defaults,nofail 0 2\" >> /etc/fstab",
    "mountpoint -q /data/automation-service-postgres || mount /data/automation-service-postgres",
    "if ! command -v docker >/dev/null 2>&1; then",
    "  if command -v dnf >/dev/null 2>&1; then",
    "    dnf install -y docker",
    "  elif command -v yum >/dev/null 2>&1; then",
    "    yum install -y docker",
    "  elif command -v apt-get >/dev/null 2>&1; then",
    "    apt-get update -y",
    "    apt-get install -y docker.io",
    "  else",
    "    echo 'Unsupported package manager. Install Docker manually.' >&2",
    "    exit 1",
    "  fi",
    "fi",
    "systemctl enable --now docker",
    "POSTGRES_PASSWORD=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.postgres_password.name} --with-decryption --query Parameter.Value --output text)",
    "docker rm -f automation-service-postgres >/dev/null 2>&1 || true",
    "docker run -d --name automation-service-postgres --restart unless-stopped --network host -v /data/automation-service-postgres:/var/lib/postgresql/data -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=\"$POSTGRES_PASSWORD\" -e POSTGRES_DB=automation postgres:16-alpine",
    "for _ in $(seq 1 30); do docker exec automation-service-postgres pg_isready -U postgres >/dev/null 2>&1 && break; sleep 5; done",
    "docker pull ${var.automation_service_image}",
    "docker rm -f automation-service >/dev/null 2>&1 || true",
    "docker run -d --name automation-service --restart unless-stopped --network host -e PORT=${var.automation_service_port} -e DATABASE_URL=\"postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/automation\" -e NAVIGATION_SERVICE_URL=http://localhost:${data.terraform_remote_state.navigation_service.outputs.navigation_service_port}/api/navigation/v1 -e AGENT_SERVICE_URL=http://localhost:${data.terraform_remote_state.agent_service.outputs.agent_service_port}/api/agent/v1 -e FLEET_SERVICE_URL=http://localhost:${data.terraform_remote_state.fleet_service.outputs.fleet_service_port}/api/fleet/v1 -e MINING_SHIP_SYMBOL=${var.mining_ship_symbol} -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} ${var.automation_service_image}",
  ]
}

resource "aws_ssm_document" "automation_service_bootstrap" {
  name            = "automation-service-bootstrap-${var.ec2_instance_id}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Docker and run automation-service + its Postgres container on shared EC2 host."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapAutomationService"
        inputs = {
          runCommand = local.automation_service_bootstrap_commands
        }
      }
    ]
  })
}

resource "aws_ssm_association" "automation_service_bootstrap" {
  name = aws_ssm_document.automation_service_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }

  depends_on = [aws_volume_attachment.automation_service_postgres_data]
}
