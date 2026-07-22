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

# No dedicated ingress rule here — navigation-service's stack owns a single shared rule
# covering all three backend ports (80/agent, 3001/fleet, 8080/navigation) from CloudFront's
# prefix list, since a separate rule per service exceeded the account's rules-per-security-group
# quota (that quota counts a prefix-list rule by the list's entry count, not as a flat 1).

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
    "docker run -d --name fleet-service --restart unless-stopped --network host -e PORT=${var.fleet_service_port} -e AGENT_SERVICE_URL=http://localhost:${data.terraform_remote_state.agent_service.outputs.agent_service_port}/api/agent/v1 -e ST_GATEWAY_URL=http://localhost:3002 -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} ${var.fleet_service_image}",
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
