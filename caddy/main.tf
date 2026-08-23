provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "personal" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "personal/terraform.tfstate"
    region = var.aws_region
  }
}

# Backend service ports are read from each stack's state so the Caddyfile routes
# stay in sync with the ports the services actually listen on.
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

data "terraform_remote_state" "automation_service" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "automation-service/terraform.tfstate"
    region = var.aws_region
  }
}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# Lets the host read the shared X-Origin-Verify secret at container-start time,
# same pattern as the DB-password parameters. The Route53 permissions Caddy needs
# for the ACME DNS-01 challenge live on the shared instance role in the personal
# infra repo (shared/main.tf), not here.
data "terraform_remote_state" "auth_service" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "auth-service/terraform.tfstate"
    region = var.aws_region
  }
}

resource "aws_iam_role_policy" "shared_ec2_caddy_ssm_parameters" {
  name = "caddy-ssm-parameters"
  role = data.terraform_remote_state.personal.outputs.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.origin_verify_param_name}"
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.ssm.target_key_arn
      }
    ]
  })
}

locals {
  # increment 3 Stage 4 / auth-design.md decision 9 — same fixed-IP plan as
  # auth-service/main.tf and agent-service/main.tf; see auth-service's
  # comment for the full explanation of why this is a hand-coordinated
  # literal across three independent Terraform stacks rather than a shared
  # variable.
  authnet_subnet   = "172.28.0.0/24"
  authnet_caddy_ip = "172.28.0.12"

  # Built on the host at bootstrap (once, then cached): stock Caddy has no
  # route53 DNS module, so a custom build with xcaddy is required. Building
  # on-host keeps everything in this repo — no separate image repo or registry
  # credentials. A pre-built, digest-pinned GHCR image would be the production
  # -grade alternative if build time or reproducibility ever matters.
  caddy_dockerfile = <<-DOCKERFILE
    FROM caddy:2-builder AS builder
    RUN xcaddy build --with github.com/caddy-dns/route53
    FROM caddy:2
    COPY --from=builder /usr/bin/caddy /usr/bin/caddy
  DOCKERFILE

  caddyfile = templatefile("${path.module}/Caddyfile.tftpl", {
    acme_email      = var.acme_email
    navigation_port = data.terraform_remote_state.navigation_service.outputs.navigation_service_port
    agent_port      = data.terraform_remote_state.agent_service.outputs.agent_service_port
    fleet_port      = data.terraform_remote_state.fleet_service.outputs.fleet_service_port
    automation_port = data.terraform_remote_state.automation_service.outputs.automation_service_port
    gateway_port    = data.terraform_remote_state.agent_service.outputs.gateway_port
    auth_port       = data.terraform_remote_state.auth_service.outputs.auth_service_port
  })

  # base64 so the multi-line Caddyfile/Dockerfile survive being carried as
  # single JSON strings in the SSM document without quoting problems.
  caddyfile_b64  = base64encode(local.caddyfile)
  dockerfile_b64 = base64encode(local.caddy_dockerfile)

  caddy_bootstrap_commands = [
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
    # Idempotent: see auth-service/main.tf's identical line — whichever of
    # the three authnet stacks' bootstraps runs first actually creates it.
    "docker network inspect authnet >/dev/null 2>&1 || docker network create --subnet ${local.authnet_subnet} authnet",
    "mkdir -p /opt/caddy",
    "echo ${local.caddyfile_b64} | base64 -d > /opt/caddy/Caddyfile",
    "ORIGIN_VERIFY_SECRET=$(aws ssm get-parameter --region ${var.aws_region} --name ${var.origin_verify_param_name} --with-decryption --query Parameter.Value --output text)",
    "if ! docker image inspect caddy-route53:latest >/dev/null 2>&1; then echo ${local.dockerfile_b64} | base64 -d | docker build -t caddy-route53:latest -; fi",
    "docker rm -f caddy >/dev/null 2>&1 || true",
    # authnet, not host (decision 9) — the Reset Agent flow carries the
    # account token from the browser through Caddy, and routing it through
    # any host-network service would expose that credential to a service
    # that has no business seeing it. Publishes 443 explicitly now (host
    # networking used to expose it implicitly); --add-host gives Caddy a way
    # to reach the four services staying on --network host, since plain
    # localhost from a bridge-networked container means the container
    # itself, not the host. Named volumes persist issued certs/account keys
    # across container restarts and redeploys, so Caddy loads the stored
    # cert instead of re-issuing (and risking Let's Encrypt rate limits).
    # They do not survive host replacement — a deliberate, rare event —
    # after which Caddy re-issues automatically.
    "docker run -d --name caddy --restart unless-stopped --network authnet --ip ${local.authnet_caddy_ip} -p 443:443 --add-host host.docker.internal:host-gateway -v /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v caddy_data:/data -v caddy_config:/config -e AWS_REGION=${var.aws_region} -e CADDY_DOMAIN=${var.backend_domain} -e ORIGIN_VERIFY_SECRET=\"$ORIGIN_VERIFY_SECRET\" caddy-route53:latest",
  ]
}

resource "aws_ssm_document" "caddy_bootstrap" {
  name            = "caddy-bootstrap-${var.ec2_instance_id}"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Build and run the Caddy edge proxy (TLS + origin auth) on the shared EC2 host."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "bootstrapCaddy"
        inputs = {
          runCommand = local.caddy_bootstrap_commands
        }
      }
    ]
  })
}

resource "aws_ssm_association" "caddy_bootstrap" {
  name = aws_ssm_document.caddy_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }
}
