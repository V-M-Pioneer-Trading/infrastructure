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

data "aws_instance" "auth_service_host" {
  instance_id = var.ec2_instance_id
}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# Self-generated: this secret only needs the two of them (st-gateway,
# auth-service) to agree, same reasoning as automation-service's
# ai_service_secret — nothing external mints it, so Terraform can.
resource "random_password" "auth_service_shared_secret" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "auth_service_shared_secret" {
  name  = "auth-service-shared-secret"
  type  = "SecureString"
  value = random_password.auth_service_shared_secret.result
}

resource "aws_ssm_parameter" "clerk_jwt_key" {
  name  = "auth-service-clerk-jwt-key"
  type  = "SecureString"
  value = var.clerk_jwt_key
}

# Lets the shared host's bootstrap script read these SecureString parameters
# at container-start time, same pattern as every sibling service.
resource "aws_iam_role_policy" "shared_ec2_auth_service_ssm_parameters" {
  name = "auth-service-ssm-parameters"
  role = data.terraform_remote_state.personal.outputs.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          aws_ssm_parameter.auth_service_shared_secret.arn,
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

# No new ingress rule: auth-service is not reachable from off-host yet (no
# Caddy route, no CloudFront behavior — increment 3 Stage 4). The existing
# 443-to-Caddy rule (navigation-service/main.tf) already covers every public
# route this host will ever expose.

resource "aws_ebs_volume" "auth_service_data" {
  availability_zone = data.aws_instance.auth_service_host.availability_zone
  encrypted         = true
  size              = var.auth_service_data_volume_size_gb
  type              = "gp3"

  tags = {
    Backup = "auth-service-daily"
  }
}

resource "aws_volume_attachment" "auth_service_data" {
  device_name = "/dev/xvdi"
  volume_id   = aws_ebs_volume.auth_service_data.id
  instance_id = var.ec2_instance_id
}

# ============================================================
# Daily EBS snapshots for the SQLite data volume (7-day retention)
# ============================================================

resource "aws_iam_role" "dlm_lifecycle" {
  name = "auth-service-dlm-role"

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

resource "aws_dlm_lifecycle_policy" "auth_service_data" {
  description        = "Daily snapshots for auth-service SQLite EBS data volume"
  execution_role_arn = aws_iam_role.dlm_lifecycle.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "auth-service-daily"
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
  # increment 3 Stage 4 / auth-design.md decision 9: authnet, a private Docker
  # bridge holding auth-service, st-gateway and Caddy — isolated from the
  # --network host containers everything else on this shared instance still
  # uses. auth-service, agent-service (st-gateway) and caddy are three
  # INDEPENDENT Terraform root modules/states, so there is no single
  # Terraform-native way to share this subnet/IP plan across them — it is
  # hand-coordinated by literal constants repeated (with this same comment)
  # in all three stacks' main.tf. If any of these three literals ever drift
  # out of sync across the repos, that is the bug to look for.
  #   172.28.0.0/24  authnet subnet (fixed, not Docker-assigned, so the
  #                  DOCKER-USER guard chain below has a stable CIDR)
  #   172.28.0.10    st-gateway  (agent-service/main.tf)
  #   172.28.0.11    auth-service (this file)
  #   172.28.0.12    caddy       (caddy/main.tf)
  # Fixed IPs matter only for the iptables rule below, which must pin an
  # exact IP:port pair — Caddy and auth-service's own container-to-container
  # calls use ordinary Docker bridge DNS (service name) and never reference
  # these addresses directly.
  authnet_subnet         = "172.28.0.0/24"
  authnet_st_gateway_ip   = "172.28.0.10"
  authnet_auth_service_ip = "172.28.0.11"
  # 3002: st-gateway's fixed port everywhere in this codebase (not a
  # variable in this stack — agent-service/variables.tf owns it, and every
  # other stack that references it already hardcodes the literal too, e.g.
  # navigation-service/main.tf's ST_GATEWAY_URL).
  st_gateway_port = 3002

  # Mounted under a per-service subdirectory (not plain /data) — the shared
  # host already has multiple services each with their own dedicated volume;
  # agent-service and automation-service set this convention.
  data_mount = "/data/auth-service"

  auth_service_bootstrap_commands = [
    "set -euo pipefail",
    "cloud-init status --wait >/dev/null 2>&1 || true",
    "DATA_DEVICE_SYMLINK=\"/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.auth_service_data.id, "-", "")}\"",
    "DATA_DEVICE=\"\"",
    "for _ in $(seq 1 30); do",
    "  if [ -e \"$DATA_DEVICE_SYMLINK\" ]; then",
    "    DATA_DEVICE=$(readlink -f \"$DATA_DEVICE_SYMLINK\")",
    "    break",
    "  fi",
    "  if [ -b /dev/xvdi ]; then",
    "    DATA_DEVICE=/dev/xvdi",
    "    break",
    "  fi",
    "  sleep 5",
    "done",
    "[ -n \"$DATA_DEVICE\" ] || { echo 'Data volume device not found.' >&2; exit 1; }",
    "if ! blkid \"$DATA_DEVICE\" >/dev/null 2>&1; then",
    "  mkfs.ext4 -F \"$DATA_DEVICE\"",
    "fi",
    "mkdir -p ${local.data_mount}",
    "DATA_UUID=$(blkid -s UUID -o value \"$DATA_DEVICE\")",
    "grep -q \"^UUID=$DATA_UUID ${local.data_mount} \" /etc/fstab || echo \"UUID=$DATA_UUID ${local.data_mount} ext4 defaults,nofail 0 2\" >> /etc/fstab",
    "mountpoint -q ${local.data_mount} || mount ${local.data_mount}",
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
    # Idempotent: whichever of the three authnet stacks' bootstraps runs
    # first actually creates it; the other two see it already exists. All
    # three carry this exact line — see the locals block above.
    "docker network inspect authnet >/dev/null 2>&1 || docker network create --subnet ${local.authnet_subnet} authnet",
    # decision 9: a bridge alone doesn't isolate authnet from --network host
    # containers — they share the host's own network stack and can still
    # reach the bridge subnet directly by IP, including via the exact DNAT
    # path a published port uses internally. So this can't be a blanket
    # "drop everything into authnet" rule: st-gateway's own published port
    # (127.0.0.1:${local.st_gateway_port}, agent-service/main.tf) is DNAT'd
    # to st-gateway's fixed bridge IP *before* DOCKER-USER evaluates the
    # packet, so that specific destination must be allowed while everything
    # else into the subnet is dropped. A custom chain, flushed and rebuilt
    # every run, keeps this idempotent without stacking duplicate DOCKER-USER
    # entries across repeated bootstraps.
    "iptables -N auth-service-authnet-guard 2>/dev/null || true",
    "iptables -F auth-service-authnet-guard",
    "iptables -A auth-service-authnet-guard -d ${local.authnet_st_gateway_ip}/32 -p tcp --dport ${local.st_gateway_port} -j RETURN",
    "iptables -A auth-service-authnet-guard -j DROP",
    "iptables -C DOCKER-USER -d ${local.authnet_subnet} -j auth-service-authnet-guard 2>/dev/null || iptables -I DOCKER-USER -d ${local.authnet_subnet} -j auth-service-authnet-guard",
    "AUTH_SERVICE_SHARED_SECRET=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.auth_service_shared_secret.name} --with-decryption --query Parameter.Value --output text)",
    "CLERK_JWT_KEY=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.clerk_jwt_key.name} --with-decryption --query Parameter.Value --output text)",
    "docker pull ${var.auth_service_image}",
    "docker rm -f auth-service >/dev/null 2>&1 || true",
    "docker run -d --name auth-service --restart unless-stopped --network authnet --ip ${local.authnet_auth_service_ip} -v ${local.data_mount}:/data -e SQLITE_DB_PATH=/data/auth.db -e PORT=${var.auth_service_port} -e ST_GATEWAY_URL=http://st-gateway:${local.st_gateway_port} -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e CLERK_JWT_KEY=\"$CLERK_JWT_KEY\" -e CLERK_ISSUER=${var.clerk_issuer} -e AUTH_SERVICE_SHARED_SECRET=\"$AUTH_SERVICE_SHARED_SECRET\" ${var.auth_service_image}",
  ]
}

resource "aws_ssm_document" "auth_service_bootstrap" {
  name            = "auth-service-bootstrap-${var.ec2_instance_id}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Docker and run auth-service on shared EC2 host."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapAuthService"
        inputs = {
          runCommand = local.auth_service_bootstrap_commands
        }
      }
    ]
  })
}

resource "aws_ssm_association" "auth_service_bootstrap" {
  name = aws_ssm_document.auth_service_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }

  depends_on = [aws_volume_attachment.auth_service_data]
}
