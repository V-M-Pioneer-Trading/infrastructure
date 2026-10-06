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

# Lets the shared host's bootstrap script decrypt SecureString parameters it
# reads at container-start time (the parameters themselves are granted in
# their owning stacks).
resource "aws_iam_role_policy" "shared_ec2_fleet_service_ssm_parameters" {
  name = "fleet-service-ssm-parameters"
  role = data.terraform_remote_state.personal.outputs.ec2_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
  # fleet_service_image with its tag stripped, so the SSM document's imageTag parameter can
  # select another tag of the same repository (deploy or roll back by sha).
  fleet_service_image_repo = try(regex("^([^@]*?)(?::[^:/@]+)?(?:@.+)?$", var.fleet_service_image)[0], var.fleet_service_image)

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
    "AUTH_INTROSPECTION_SECRET=$(read_secure_parameter ${data.terraform_remote_state.auth_service.outputs.auth_introspection_secret_parameter_name}) || exit 1",
    "[ -n \"$AUTH_INTROSPECTION_SECRET\" ] || { echo 'FATAL: AUTH_INTROSPECTION_SECRET is empty.' >&2; exit 1; }",
    # Image digest before and after the pull, as in auth-service's bootstrap:
    # with `:latest`, the SSM command output is what says whether this run
    # changed the image.
    # Pin by sha (meta#89): the document's optional imageTag parameter
    # (default `latest`, which is what the association sends) picks the tag
    # of the fleet-service image. CI sends the sha its run built; a manual
    # send-command with an older sha rolls back. Same parameter, pattern and
    # script as agent-service's and auth-service's bootstraps. The SSM
    # allowedPattern already limits it to `latest` or sha-<40 hex>; the case
    # below re-checks after substitution so a malformed value can never reach
    # docker. With `latest` the image reference is exactly
    # var.fleet_service_image, as before.
    "IMAGE_TAG='{{ imageTag }}'",
    "case \"$IMAGE_TAG\" in latest|sha-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) echo 'FATAL: imageTag must be latest or sha-<40 hex>.' >&2; exit 1 ;; esac",
    "if [ \"$IMAGE_TAG\" = latest ]; then IMAGE_REF='${var.fleet_service_image}'; else IMAGE_REF='${local.fleet_service_image_repo}':\"$IMAGE_TAG\"; fi",
    "echo \"fleet-service image: $IMAGE_REF\"",
    "if [ \"$IMAGE_TAG\" != latest ]; then",
    "  echo 'NOTE: pinned to '\"$IMAGE_TAG\"'; the container is replaced.'",
    "fi",
    "IMAGE_DIGEST_BEFORE=$(docker image inspect --format '{{join .RepoDigests \",\"}}' \"$IMAGE_REF\" 2>/dev/null || true)",
    "echo \"fleet-service image digest before pull: $IMAGE_DIGEST_BEFORE\"",
    "docker pull \"$IMAGE_REF\"",
    "IMAGE_DIGEST_AFTER=$(docker image inspect --format '{{join .RepoDigests \",\"}}' \"$IMAGE_REF\" 2>/dev/null || true)",
    "echo \"fleet-service image digest after pull:  $IMAGE_DIGEST_AFTER\"",
    "docker rm -f fleet-service >/dev/null 2>&1 || true",
    # Token verification is auth-service's (decision 21, meta#80); this service
    # holds no Clerk verification key.
    "docker run -d --name fleet-service --restart unless-stopped --network host -e PORT=${var.fleet_service_port} -e AGENT_SERVICE_URL=http://localhost:${data.terraform_remote_state.agent_service.outputs.agent_service_port}/api/agent/v1 -e ST_GATEWAY_URL=http://localhost:3002 -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e AUTH_INTROSPECTION_URL=${data.terraform_remote_state.auth_service.outputs.auth_introspection_url} -e AUTH_INTROSPECTION_SECRET=\"$AUTH_INTROSPECTION_SECRET\" \"$IMAGE_REF\"",
    # `docker run -d` returning 0 only means the container was created. From
    # meta#80 step 5 the image refuses to start on a missing or bad
    # AUTH_INTROSPECTION_* value. With --restart unless-stopped such a
    # container is restarted over and over, and Docker reports
    # State.Running=true for most of that loop, so a running check passes a
    # crash-looping container. Poll /api/fleet/health for up to ~90 s
    # instead, then a non-zero exit so the SSM command is reported as Failed
    # rather than Success. Same check as auth-service's and agent-service's
    # bootstraps.
    "FLEET_HEALTHY=no",
    "_attempt=0",
    "while [ \"$_attempt\" -lt 30 ]; do",
    "  _attempt=$((_attempt + 1))",
    "  if curl -fs -o /dev/null --max-time 2 http://127.0.0.1:${var.fleet_service_port}/api/fleet/health; then",
    "    FLEET_HEALTHY=yes",
    "    break",
    "  fi",
    "  sleep 3",
    "done",
    "if [ \"$FLEET_HEALTHY\" != yes ]; then",
    "  echo 'FATAL: fleet-service did not answer GET /api/fleet/health on 127.0.0.1:${var.fleet_service_port} within ~90s of docker run. Container state, restart count and the last 50 log lines follow.' >&2",
    "  docker inspect -f 'state={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} restarts={{.RestartCount}} exit={{.State.ExitCode}} err={{.State.Error}}' fleet-service >&2 2>/dev/null || echo 'no such container' >&2",
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
    # SSM rejects any bare `{{ word }}` that is not a declared parameter (e.g.
    # `{{end}}`, `{{else}}`); docker --format templates in the script must contain
    # a dot or a space. `terraform plan` cannot catch this, only apply fails.
    parameters = {
      imageTag = {
        type           = "String"
        description    = "Tag of the fleet-service image to run: latest (default) or sha-<40 hex git sha> (CI deploys the sha it built; an older sha rolls back)."
        default        = "latest"
        allowedPattern = "^(latest|sha-[0-9a-f]{40})$"
      }
    }
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
