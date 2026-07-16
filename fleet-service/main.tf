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

data "terraform_remote_state" "agent_service" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "agent-service/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc_security_group_ingress_rule" "fleet_service_from_cloudfront" {
  description       = "Allow fleet-service traffic from CloudFront only."
  security_group_id = data.terraform_remote_state.personal.outputs.ec2_security_group_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = var.fleet_service_port
  to_port           = var.fleet_service_port
  ip_protocol       = "tcp"
}

locals {
  fleet_service_bootstrap_commands = [
    "set -euo pipefail",
    "cloud-init status --wait >/dev/null 2>&1 || true",
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
    "docker pull ${var.fleet_service_image}",
    "docker rm -f fleet-service >/dev/null 2>&1 || true",
    "docker run -d --name fleet-service --restart unless-stopped --network host -e PORT=${var.fleet_service_port} -e AGENT_SERVICE_URL=http://localhost:${data.terraform_remote_state.agent_service.outputs.agent_service_port} -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} ${var.fleet_service_image}",
  ]
}

resource "aws_ssm_document" "fleet_service_bootstrap" {
  name            = "fleet-service-bootstrap-${var.ec2_instance_id}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Install Docker and run fleet-service on shared EC2 host."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapFleetService"
        inputs = {
          runCommand = local.fleet_service_bootstrap_commands
        }
      }
    ]
  })
}

resource "aws_ssm_association" "fleet_service_bootstrap" {
  name = aws_ssm_document.fleet_service_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }
}
