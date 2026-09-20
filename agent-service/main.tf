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

data "aws_instance" "agent_service_host" {
  instance_id = var.ec2_instance_id
}

# st-gateway's container lives in this stack (see the note above the bootstrap
# script), but the credential it presents to auth-service is owned by
# auth-service's stack. Same cross-stack read caddy/main.tf already does for
# the same reason — increment 3 Stage 5 / auth-design.md decision 5.
data "terraform_remote_state" "auth_service" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "auth-service/terraform.tfstate"
    region = var.aws_region
  }
}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

resource "random_password" "mysql_root" {
  length  = 24
  special = false
}

resource "random_password" "mysql_app" {
  length  = 24
  special = false
}

resource "aws_ssm_parameter" "mysql_root_password" {
  name  = "agent-service-mysql-root-password"
  type  = "SecureString"
  value = random_password.mysql_root.result
}

resource "aws_ssm_parameter" "mysql_app_password" {
  name  = "agent-service-mysql-password"
  type  = "SecureString"
  value = random_password.mysql_app.result
}

resource "aws_ssm_parameter" "clerk_jwt_key" {
  name  = "agent-service-clerk-jwt-key"
  type  = "SecureString"
  value = var.clerk_jwt_key
}

# Lets the shared host's bootstrap script read these SecureString parameters at
# container-start time, mirroring how navigation-service's GHCR PAT used to work.
resource "aws_iam_role_policy" "shared_ec2_agent_service_ssm_parameters" {
  name = "agent-service-ssm-parameters"
  role = data.terraform_remote_state.personal.outputs.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          aws_ssm_parameter.mysql_root_password.arn,
          aws_ssm_parameter.mysql_app_password.arn,
          aws_ssm_parameter.clerk_jwt_key.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
      }
    ]
  })
}

// No dedicated ingress rule here — navigation-service's stack owns a single shared rule
// covering all three backend ports (80/agent, 3001/fleet, 8080/navigation) from CloudFront's
// prefix list, since a separate rule per service exceeded the account's rules-per-security-group
// quota (that quota counts a prefix-list rule by the list's entry count, not as a flat 1).

resource "aws_ebs_volume" "agent_service_mysql_data" {
  availability_zone = data.aws_instance.agent_service_host.availability_zone
  encrypted         = true
  size              = var.agent_service_mysql_data_volume_size_gb
  type              = "gp3"

  tags = {
    Backup = "agent-service-mysql-daily"
  }
}

resource "aws_volume_attachment" "agent_service_mysql_data" {
  device_name = "/dev/xvdg"
  volume_id   = aws_ebs_volume.agent_service_mysql_data.id
  instance_id = var.ec2_instance_id
}

# ============================================================
# Daily EBS snapshots for the MySQL data volume (7-day retention)
# ============================================================

resource "aws_iam_role" "dlm_lifecycle" {
  name = "agent-service-dlm-role"

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

resource "aws_dlm_lifecycle_policy" "agent_service_mysql_data" {
  description        = "Daily snapshots for agent-service MySQL EBS data volume"
  execution_role_arn = aws_iam_role.dlm_lifecycle.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "agent-service-mysql-daily"
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
  # increment 3 Stage 4 / auth-design.md decision 9 — same fixed-IP plan as
  # auth-service/main.tf and caddy/main.tf; see that comment for the full
  # explanation of why this is a hand-coordinated literal across three
  # independent Terraform stacks rather than a shared variable.
  authnet_subnet     = "172.28.0.0/24"
  authnet_gateway_ip = "172.28.0.10"

  agent_service_bootstrap_commands = [
    "set -euo pipefail",
    "cloud-init status --wait >/dev/null 2>&1 || true",
    "DATA_DEVICE_SYMLINK=\"/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.agent_service_mysql_data.id, "-", "")}\"",
    "DATA_DEVICE=\"\"",
    "for _ in $(seq 1 30); do",
    "  if [ -e \"$DATA_DEVICE_SYMLINK\" ]; then",
    "    DATA_DEVICE=$(readlink -f \"$DATA_DEVICE_SYMLINK\")",
    "    break",
    "  fi",
    "  if [ -b /dev/xvdg ]; then",
    "    DATA_DEVICE=/dev/xvdg",
    "    break",
    "  fi",
    "  sleep 5",
    "done",
    "[ -n \"$DATA_DEVICE\" ] || { echo 'Data volume device not found.' >&2; exit 1; }",
    "if ! blkid \"$DATA_DEVICE\" >/dev/null 2>&1; then",
    "  mkfs.ext4 -F \"$DATA_DEVICE\"",
    "fi",
    "mkdir -p /data/agent-service-mysql",
    "DATA_UUID=$(blkid -s UUID -o value \"$DATA_DEVICE\")",
    "grep -q \"^UUID=$DATA_UUID /data/agent-service-mysql \" /etc/fstab || echo \"UUID=$DATA_UUID /data/agent-service-mysql ext4 defaults,nofail 0 2\" >> /etc/fstab",
    "mountpoint -q /data/agent-service-mysql || mount /data/agent-service-mysql",
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
    "MYSQL_ROOT_PASSWORD=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.mysql_root_password.name} --with-decryption --query Parameter.Value --output text)",
    "MYSQL_APP_PASSWORD=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.mysql_app_password.name} --with-decryption --query Parameter.Value --output text)",
    "CLERK_JWT_KEY=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.clerk_jwt_key.name} --with-decryption --query Parameter.Value --output text)",
    # st-gateway's half of the auth-service shared secret (decision 5). The
    # parameter belongs to auth-service's stack; the shared EC2 role is already
    # granted GetParameter on it there, so no extra IAM is needed here — only
    # the name, read from that stack's output.
    "AUTH_SERVICE_SHARED_SECRET=$(aws ssm get-parameter --region ${var.aws_region} --name ${data.terraform_remote_state.auth_service.outputs.auth_service_shared_secret_parameter_name} --with-decryption --query Parameter.Value --output text)",
    "docker rm -f agent-service-mysql >/dev/null 2>&1 || true",
    # Pinned to the current major (9) rather than :latest — an unpinned tag would
    # silently pull the next MySQL major on the next host rebuild, risking an
    # incompatible on-disk data format against the retained EBS volume. Pinned to
    # the running major, not below it: MySQL refuses to start on a data dir from a
    # newer major, so a downgrade (e.g. to 8.4) would break the DB on redeploy.
    # The `mysql:9` tag tracks the latest 9.x; in-place minor upgrades are safe.
    "docker run -d --name agent-service-mysql --restart unless-stopped --network host -v /data/agent-service-mysql:/var/lib/mysql -e MYSQL_ROOT_PASSWORD=\"$MYSQL_ROOT_PASSWORD\" -e MYSQL_DATABASE=vnm-agent-db -e MYSQL_USER=user -e MYSQL_PASSWORD=\"$MYSQL_APP_PASSWORD\" mysql:9",
    "for _ in $(seq 1 30); do docker exec agent-service-mysql mysqladmin ping -h localhost -u root -p\"$MYSQL_ROOT_PASSWORD\" >/dev/null 2>&1 && break; sleep 5; done",
    # Idempotent: see auth-service/main.tf's identical line — whichever of
    # the three authnet stacks' bootstraps runs first actually creates it.
    "docker network inspect authnet >/dev/null 2>&1 || docker network create --subnet ${local.authnet_subnet} authnet",
    "docker pull ${var.gateway_image}",
    "docker rm -f st-gateway >/dev/null 2>&1 || true",
    # authnet, not host — decision 9. Still publishes on 127.0.0.1 so
    # agent-service, navigation-service, fleet-service and automation-service
    # (all staying on --network host) keep reaching it at the exact same
    # http://localhost:${var.gateway_port} they already use — no changes
    # needed in any of those four services. auth-service and Caddy, both also
    # on authnet, reach it via bridge DNS (http://st-gateway:${var.gateway_port})
    # instead.
    # AUTH_SERVICE_SHARED_SECRET and CLERK_JWT_KEY are both required at
    # startup by st-gateway's config.ts — it refuses to boot without them
    # rather than running with authentication silently off, so these must be
    # in place before the injecting image is deployed. auth-service is reached
    # by bridge DNS: both containers are on authnet, so st-gateway addresses
    # it by container name — the same idiom st-gateway's own AUTH_SERVICE_URL
    # already uses, and unaffected by meta#80 step 3, which additionally
    # publishes auth-service on 127.0.0.1 for the four --network host
    # services. Bridge members use bridge DNS; host-network services use
    # loopback. Neither needs the other's address.
    "docker run -d --name st-gateway --restart unless-stopped --network authnet --ip ${local.authnet_gateway_ip} -p 127.0.0.1:${var.gateway_port}:${var.gateway_port} -e PORT=${var.gateway_port} -e SPACETRADERS_BASE_URL=https://api.spacetraders.io/v2 -e AUTH_SERVICE_URL=http://auth-service:${data.terraform_remote_state.auth_service.outputs.auth_service_port} -e AUTH_SERVICE_SHARED_SECRET=\"$AUTH_SERVICE_SHARED_SECRET\" -e CLERK_JWT_KEY=\"$CLERK_JWT_KEY\" -e CLERK_ISSUER=${var.clerk_issuer} ${var.gateway_image}",
    "docker pull ${var.agent_service_image}",
    "docker rm -f agent-service >/dev/null 2>&1 || true",
    "docker run -d --name agent-service --restart unless-stopped --network host -e MYSQL_HOST=localhost -e MYSQL_PORT=3306 -e MYSQL_USER=user -e MYSQL_PASSWORD=\"$MYSQL_APP_PASSWORD\" -e MYSQL_DATABASE=vnm-agent-db -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e ST_GATEWAY_URL=http://localhost:${var.gateway_port} -e CLERK_JWT_KEY=\"$CLERK_JWT_KEY\" -e CLERK_ISSUER=${var.clerk_issuer} ${var.agent_service_image}",
  ]
}

resource "aws_ssm_document" "agent_service_bootstrap" {
  name            = "agent-service-bootstrap-${var.ec2_instance_id}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Docker and run agent-service + its MySQL container on shared EC2 host."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapAgentService"
        inputs = {
          runCommand = local.agent_service_bootstrap_commands
        }
      }
    ]
  })
}

resource "aws_ssm_association" "agent_service_bootstrap" {
  name = aws_ssm_document.agent_service_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }

  depends_on = [aws_volume_attachment.agent_service_mysql_data]
}
