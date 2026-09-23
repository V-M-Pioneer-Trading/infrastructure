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

# auth-service publishes the introspection endpoint URL and the name of the
# SSM parameter holding the caller secret (meta#80 step 3). Read, not
# redeclared: the shared EC2 role is already allowed GetParameter on that
# parameter by auth-service's own policy, so this stack needs no IAM for it.
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

resource "aws_ssm_parameter" "clerk_jwt_key" {
  name  = "fleet-service-clerk-jwt-key"
  type  = "SecureString"
  value = var.clerk_jwt_key
}

# Lets the shared host's bootstrap script read this SecureString parameter at
# container-start time, mirroring agent-service's MySQL password pattern.
resource "aws_iam_role_policy" "shared_ec2_fleet_service_ssm_parameters" {
  name = "fleet-service-ssm-parameters"
  role = data.terraform_remote_state.personal.outputs.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = aws_ssm_parameter.clerk_jwt_key.arn
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
    # Secret reads, all BEFORE `docker rm -f`, and a failed or empty read
    # aborts the script with the running container untouched. From meta#80
    # step 5 the image refuses to start without AUTH_INTROSPECTION_SECRET, so
    # an unguarded `$(...)` that read back empty (the AWS CLI prints nothing
    # on AccessDenied, and `None` for a parameter that resolves to nothing)
    # would replace a healthy container with a crash-looping one. Same guard
    # and retry as auth-service's bootstrap; the retry covers IAM propagation.
    "read_secure_parameter() {",
    "  _param_name=\"$1\"",
    "  _param_value=\"\"",
    "  _attempt=0",
    "  while [ \"$_attempt\" -lt 12 ]; do",
    "    _attempt=$((_attempt + 1))",
    "    _param_value=$(aws ssm get-parameter --region ${var.aws_region} --name \"$_param_name\" --with-decryption --query Parameter.Value --output text 2>/dev/null || true)",
    "    if [ -n \"$_param_value\" ] && [ \"$_param_value\" != None ]; then",
    "      printf '%s' \"$_param_value\"",
    "      return 0",
    "    fi",
    "    echo \"waiting for SSM parameter $_param_name to read back non-empty (attempt $_attempt/12)\" >&2",
    "    sleep 5",
    "  done",
    "  echo \"FATAL: SSM parameter $_param_name read back empty after ~60s. Refusing to restart fleet-service with an empty secret; the running container is untouched.\" >&2",
    "  return 1",
    "}",
    # CLERK_JWT_KEY/CLERK_ISSUER stay injected until step 10: an image from
    # before step 5 still needs them, and redeploying the previous image tag
    # is this service's rollback. The migrated image ignores them.
    "CLERK_JWT_KEY=$(read_secure_parameter ${aws_ssm_parameter.clerk_jwt_key.name}) || exit 1",
    "AUTH_INTROSPECTION_SECRET=$(read_secure_parameter ${data.terraform_remote_state.auth_service.outputs.auth_introspection_secret_parameter_name}) || exit 1",
    "[ -n \"$CLERK_JWT_KEY\" ] || { echo 'FATAL: CLERK_JWT_KEY is empty.' >&2; exit 1; }",
    "[ -n \"$AUTH_INTROSPECTION_SECRET\" ] || { echo 'FATAL: AUTH_INTROSPECTION_SECRET is empty.' >&2; exit 1; }",
    # Image digest before and after the pull, as in auth-service's bootstrap:
    # the tag is `:latest`, so the SSM command output is what says whether
    # this run changed the image.
    "IMAGE_DIGEST_BEFORE=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.fleet_service_image} 2>/dev/null || true)",
    "echo \"fleet-service image digest before pull: $IMAGE_DIGEST_BEFORE\"",
    "docker pull ${var.fleet_service_image}",
    "IMAGE_DIGEST_AFTER=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.fleet_service_image} 2>/dev/null || true)",
    "echo \"fleet-service image digest after pull:  $IMAGE_DIGEST_AFTER\"",
    "docker rm -f fleet-service >/dev/null 2>&1 || true",
    "docker run -d --name fleet-service --restart unless-stopped --network host -e PORT=${var.fleet_service_port} -e AGENT_SERVICE_URL=http://localhost:${data.terraform_remote_state.agent_service.outputs.agent_service_port}/api/agent/v1 -e ST_GATEWAY_URL=http://localhost:3002 -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e CLERK_JWT_KEY=\"$CLERK_JWT_KEY\" -e CLERK_ISSUER=${var.clerk_issuer} -e AUTH_INTROSPECTION_URL=${data.terraform_remote_state.auth_service.outputs.auth_introspection_url} -e AUTH_INTROSPECTION_SECRET=\"$AUTH_INTROSPECTION_SECRET\" ${var.fleet_service_image}",
    # `docker run -d` returning 0 only means the container was created. From
    # meta#80 step 5 the image refuses to start on a missing or bad
    # AUTH_INTROSPECTION_* value, which shows up as a container that is no
    # longer running a moment later. Short retry, then a non-zero exit so the
    # SSM command is reported as Failed rather than Success. Same check as
    # auth-service's bootstrap.
    "FLEET_RUNNING=no",
    "_attempt=0",
    "while [ \"$_attempt\" -lt 10 ]; do",
    "  _attempt=$((_attempt + 1))",
    "  if [ \"$(docker inspect -f '{{.State.Running}}' fleet-service 2>/dev/null || echo false)\" = true ]; then",
    "    FLEET_RUNNING=yes",
    "    break",
    "  fi",
    "  sleep 3",
    "done",
    "if [ \"$FLEET_RUNNING\" != yes ]; then",
    "  echo 'FATAL: fleet-service is not running ~30s after docker run. Container state and the last 50 log lines follow.' >&2",
    "  docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}' fleet-service >&2 2>/dev/null || echo 'no such container' >&2",
    "  docker logs --tail 50 fleet-service >&2 2>&1 || true",
    "  exit 1",
    "fi",
    "echo \"fleet-service is running on port ${var.fleet_service_port}.\"",
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
