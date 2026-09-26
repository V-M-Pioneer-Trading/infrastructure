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

data "aws_instance" "navigation_service_host" {
  instance_id = var.ec2_instance_id
}

# KMS resource-based matching needs the key ARN, not the alias ARN.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

# Until meta#80 step 7 navigation-service verified Clerk session JWTs locally
# (auth-design.md decision 10) and refused to start without this key. The
# migrated image ignores it; it stays injected until step 10 so that
# redeploying the previous image tag, this service's rollback, still works.
resource "aws_ssm_parameter" "clerk_jwt_key" {
  name  = "navigation-service-clerk-jwt-key"
  type  = "SecureString"
  value = var.clerk_jwt_key
}

resource "aws_iam_role_policy" "shared_ec2_navigation_service_ssm_parameters" {
  name = "navigation-service-ssm-parameters"
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
    # Secret reads, all BEFORE `docker rm -f`, and a failed or empty read
    # aborts the script with the running container untouched. From meta#80
    # step 7 the image refuses to start without AUTH_INTROSPECTION_SECRET, so
    # an unguarded `$(...)` that read back empty (the AWS CLI prints nothing
    # on AccessDenied, and `None` for a parameter that resolves to nothing)
    # would replace a healthy container with a crash-looping one. Same guard
    # and retry as fleet-service's and auth-service's bootstraps; the retry
    # covers IAM propagation.
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
    "  echo \"FATAL: SSM parameter $_param_name read back empty after ~60s. Refusing to restart navigation-service with an empty secret; the running container is untouched.\" >&2",
    "  return 1",
    "}",
    # CLERK_JWT_KEY/CLERK_ISSUER stay injected until step 10: an image from
    # before step 7 still needs them, and redeploying the previous image tag
    # is this service's rollback. The migrated image ignores them.
    "CLERK_JWT_KEY=$(read_secure_parameter ${aws_ssm_parameter.clerk_jwt_key.name}) || exit 1",
    "AUTH_INTROSPECTION_SECRET=$(read_secure_parameter ${data.terraform_remote_state.auth_service.outputs.auth_introspection_secret_parameter_name}) || exit 1",
    "[ -n \"$CLERK_JWT_KEY\" ] || { echo 'FATAL: CLERK_JWT_KEY is empty.' >&2; exit 1; }",
    "[ -n \"$AUTH_INTROSPECTION_SECRET\" ] || { echo 'FATAL: AUTH_INTROSPECTION_SECRET is empty.' >&2; exit 1; }",
    # Image digest before and after the pull, as in fleet-service's and
    # auth-service's bootstraps: the tag is `:latest`, so the SSM command
    # output is what says whether this run changed the image.
    "IMAGE_DIGEST_BEFORE=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.navigation_service_image} 2>/dev/null || true)",
    "echo \"navigation-service image digest before pull: $IMAGE_DIGEST_BEFORE\"",
    "docker pull ${var.navigation_service_image}",
    "IMAGE_DIGEST_AFTER=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.navigation_service_image} 2>/dev/null || true)",
    "echo \"navigation-service image digest after pull:  $IMAGE_DIGEST_AFTER\"",
    "docker rm -f navigation-service >/dev/null 2>&1 || true",
    // --network host (not -p port:8080, unlike the pre-existing config): navigation-service calls
    // st-gateway via ST_GATEWAY_URL, defaulting to http://localhost:3002 — under bridge networking
    // that "localhost" is the container's own loopback, not the shared EC2 host where st-gateway
    // actually listens, so every upstream SpaceTraders call connection-refused (meta bug, found
    // while investigating prod's /api/v1/systems/*/waypoints 500s).
    "docker run -d --name navigation-service --restart unless-stopped --network host -v /data:/data -e SQLITE_DB_PATH=/data/nav.db -e SPRING_PROFILES_ACTIVE=prod -e ST_GATEWAY_URL=http://localhost:3002 -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e CLERK_JWT_KEY=\"$CLERK_JWT_KEY\" -e CLERK_ISSUER=${var.clerk_issuer} -e AUTH_INTROSPECTION_URL=${data.terraform_remote_state.auth_service.outputs.auth_introspection_url} -e AUTH_INTROSPECTION_SECRET=\"$AUTH_INTROSPECTION_SECRET\" ${var.navigation_service_image}",
    # `docker run -d` returning 0 only means the container was created. From
    # meta#80 step 7 the image refuses to start on a missing or bad
    # AUTH_INTROSPECTION_* value. With --restart unless-stopped such a
    # container is restarted over and over, and Docker reports
    # State.Running=true for most of that loop, so a running check passes a
    # crash-looping container. Poll /health instead, then a non-zero exit so
    # the SSM command is reported as Failed rather than Success. Same check as
    # fleet-service's, agent-service's and auth-service's bootstraps, but with
    # a longer window (60 x 3 s, ~180 s instead of ~90 s): navigation-service
    # is a Spring Boot JVM, and on this shared t4g host a cold start with
    # drained CPU credits, or alongside other containers starting, takes far
    # longer than the Node and Go services' to answer. The window is headroom,
    # not a measurement; a healthy container that answers late is not removed
    # by a Failed command, only reported.
    "NAVIGATION_HEALTHY=no",
    "_attempt=0",
    "while [ \"$_attempt\" -lt 60 ]; do",
    "  _attempt=$((_attempt + 1))",
    "  if curl -fs -o /dev/null --max-time 2 http://127.0.0.1:${var.navigation_service_port}/health; then",
    "    NAVIGATION_HEALTHY=yes",
    "    break",
    "  fi",
    "  sleep 3",
    "done",
    "if [ \"$NAVIGATION_HEALTHY\" != yes ]; then",
    "  echo 'FATAL: navigation-service did not answer GET /health on 127.0.0.1:${var.navigation_service_port} within ~180s of docker run. Container state, restart count and the last 50 log lines follow.' >&2",
    "  docker inspect -f 'state={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} restarts={{.RestartCount}} exit={{.State.ExitCode}} err={{.State.Error}}' navigation-service >&2 2>/dev/null || echo 'no such container' >&2",
    "  docker logs --tail 50 navigation-service >&2 2>&1 || true",
    "  exit 1",
    "fi",
    "echo \"navigation-service is running on port ${var.navigation_service_port}.\"",
  ]
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

// Only 443 is exposed now: the on-host Caddy edge proxy is the single service
// CloudFront reaches, terminating TLS and routing to the backend containers over
// localhost. The old 80-8080 span (one rule for navigation/agent/fleet/automation
// /st-gateway ports) is gone — those ports are no longer reachable from off-host.
// Source stays the CloudFront origin-facing prefix list.
resource "aws_vpc_security_group_ingress_rule" "shared_backend_ports_from_cloudfront" {
  description       = "Allow HTTPS from CloudFront to the Caddy edge proxy only."
  security_group_id = data.terraform_remote_state.personal.outputs.ec2_security_group_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  from_port         = 443
  to_port           = 443
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
