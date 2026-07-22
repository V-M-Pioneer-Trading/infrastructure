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

data "aws_instance" "navigation_service_host" {
  instance_id = var.ec2_instance_id
}

locals {
  navigation_service_bootstrap_commands = [
    "set -euo pipefail",
    "cloud-init status --wait >/dev/null 2>&1 || true",
    "DATA_DEVICE_SYMLINK=\"/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.navigation_service_data.id, "-", "")}\"",
    "DATA_DEVICE=\"\"",
    "for _ in $(seq 1 30); do",
    "  if [ -e \"$DATA_DEVICE_SYMLINK\" ]; then",
    "    DATA_DEVICE=$(readlink -f \"$DATA_DEVICE_SYMLINK\")",
    "    break",
    "  fi",
    "  if [ -b /dev/xvdf ]; then",
    "    DATA_DEVICE=/dev/xvdf",
    "    break",
    "  fi",
    "  sleep 5",
    "done",
    "[ -n \"$DATA_DEVICE\" ] || { echo 'Data volume device not found.' >&2; exit 1; }",
    "if ! blkid \"$DATA_DEVICE\" >/dev/null 2>&1; then",
    "  mkfs.ext4 -F \"$DATA_DEVICE\"",
    "fi",
    "mkdir -p /data",
    "DATA_UUID=$(blkid -s UUID -o value \"$DATA_DEVICE\")",
    "grep -q \"^UUID=$DATA_UUID /data \" /etc/fstab || echo \"UUID=$DATA_UUID /data ext4 defaults,nofail 0 2\" >> /etc/fstab",
    "mountpoint -q /data || mount /data",
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
    "docker pull ${var.navigation_service_image}",
    "docker rm -f navigation-service >/dev/null 2>&1 || true",
    // --network host (not -p port:8080, unlike the pre-existing config): navigation-service calls
    // st-gateway via ST_GATEWAY_URL, defaulting to http://localhost:3002 — under bridge networking
    // that "localhost" is the container's own loopback, not the shared EC2 host where st-gateway
    // actually listens, so every upstream SpaceTraders call connection-refused (meta bug, found
    // while investigating prod's /api/v1/systems/*/waypoints 500s).
    "docker run -d --name navigation-service --restart unless-stopped --network host -v /data:/data -e SQLITE_DB_PATH=/data/nav.db -e SPRING_PROFILES_ACTIVE=prod -e ST_GATEWAY_URL=http://localhost:3002 -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} ${var.navigation_service_image}",
  ]
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

// Covers navigation-service (8080), agent-service (80), and fleet-service (3001) in one rule.
// AWS's "rules per security group" quota counts a prefix-list-referencing rule by that list's
// entry count (45 for CloudFront's), not as a flat 1 — a separate rule per service exceeded the
// default 60-rule quota, so all three backend ports share this single rule instead.
resource "aws_vpc_security_group_ingress_rule" "shared_backend_ports_from_cloudfront" {
  description       = "Allow navigation/agent/fleet-service traffic from CloudFront only."
  security_group_id = data.terraform_remote_state.personal.outputs.ec2_security_group_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 80
  to_port           = 8080
  ip_protocol       = "tcp"
}

resource "aws_ebs_volume" "navigation_service_data" {
  availability_zone = data.aws_instance.navigation_service_host.availability_zone
  encrypted         = true
  size              = var.navigation_service_data_volume_size_gb
  type              = "gp3"

  tags = {
    Backup = "navigation-service-daily"
  }
}

resource "aws_volume_attachment" "navigation_service_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.navigation_service_data.id
  instance_id = var.ec2_instance_id
}

# ============================================================
# Daily EBS snapshots for the nav.db data volume (7-day retention)
# ============================================================

resource "aws_iam_role" "dlm_lifecycle" {
  name = "navigation-service-dlm-role"

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

resource "aws_dlm_lifecycle_policy" "navigation_service_data" {
  description        = "Daily snapshots for navigation-service EBS data volume"
  execution_role_arn = aws_iam_role.dlm_lifecycle.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "navigation-service-daily"
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

resource "aws_ssm_document" "navigation_service_bootstrap" {
  name            = "navigation-service-bootstrap-${var.ec2_instance_id}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Docker and run navigation-service on shared EC2 host."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapNavigationService"
        inputs = {
          runCommand = local.navigation_service_bootstrap_commands
        }
      }
    ]
  })
}

resource "aws_ssm_association" "navigation_service_bootstrap" {
  name = aws_ssm_document.navigation_service_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }

  depends_on = [aws_volume_attachment.navigation_service_data]
}
