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

# auth-service publishes the introspection endpoint URL and the name of the
# SSM parameter holding the caller secret (meta#80 step 3); from meta#59
# (decision 22) also the M2M token URL and the name of this caller's own
# secret parameter. Read, not
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
        Effect = "Allow"
        Action = "ssm:GetParameter"
        Resource = [
          aws_ssm_parameter.postgres_password.arn,
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
    // Postgres's initdb refuses to run against a non-empty directory, and a freshly
    // mkfs.ext4'd volume always has a lost+found dir at its root — so Postgres's data
    // dir has to be a subdirectory of the mount point, not the mount point itself.
    "mkdir -p /data/automation-service-postgres/pgdata",
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
    # Secret reads, all BEFORE any `docker rm -f`, and a failed or empty read
    # aborts the script with the running containers untouched. From meta#80
    # step 8 the image refuses to start without AUTH_INTROSPECTION_SECRET, so
    # an unguarded `$(...)` that read back empty (the AWS CLI prints nothing
    # on AccessDenied, and `None` for a parameter that resolves to nothing)
    # would replace a healthy container with a crash-looping one. Same guard
    # and retry as auth-service's bootstrap; the retry covers IAM propagation.
    # No IAM change for the introspection secret: auth-service's own policy
    # already grants the shared EC2 role GetParameter on it.
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
    "  echo \"FATAL: SSM parameter $_param_name read back empty after ~60s. Refusing to restart automation-service with an empty secret; the running containers are untouched.\" >&2",
    "  return 1",
    "}",
    "POSTGRES_PASSWORD=$(read_secure_parameter ${aws_ssm_parameter.postgres_password.name}) || exit 1",
    "AUTH_INTROSPECTION_SECRET=$(read_secure_parameter ${data.terraform_remote_state.auth_service.outputs.auth_introspection_secret_parameter_name}) || exit 1",
    # meta#59 / decision 22 (2026-09-30): automation-service holds no Clerk key;
    # it presents this caller secret to auth-service, which mints its M2M
    # token. Read by name from auth-service's remote state; that stack's policy
    # already grants the read. Requires auth-service applied first.
    "AUTH_M2M_CALLER_SECRET=$(read_secure_parameter ${data.terraform_remote_state.auth_service.outputs.auth_m2m_caller_secret_automation_service_parameter_name}) || exit 1",
    "[ -n \"$POSTGRES_PASSWORD\" ] || { echo 'FATAL: POSTGRES_PASSWORD is empty.' >&2; exit 1; }",
    "[ -n \"$AUTH_INTROSPECTION_SECRET\" ] || { echo 'FATAL: AUTH_INTROSPECTION_SECRET is empty.' >&2; exit 1; }",
    "[ -n \"$AUTH_M2M_CALLER_SECRET\" ] || { echo 'FATAL: AUTH_M2M_CALLER_SECRET is empty.' >&2; exit 1; }",
    # Pulled before anything is stopped, so a failed pull (set -e) leaves the
    # running service and its database untouched.
    # Image digest before and after the pull, as in auth-service's bootstrap:
    # the tag is `:latest`, so the SSM command output is what says whether
    # this run changed the image.
    "IMAGE_DIGEST_BEFORE=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.automation_service_image} 2>/dev/null || true)",
    "echo \"automation-service image digest before pull: $IMAGE_DIGEST_BEFORE\"",
    "docker pull ${var.automation_service_image}",
    "IMAGE_DIGEST_AFTER=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.automation_service_image} 2>/dev/null || true)",
    "echo \"automation-service image digest after pull:  $IMAGE_DIGEST_AFTER\"",
    # Graceful stop (automation-service#46) BEFORE anything else is replaced.
    # `docker stop` sends SIGTERM, which the service now handles: it persists
    # any in-flight arm/pause/abort, drains its scheduler ticks and closes its
    # pool, within an 8 s deadline; -t 9 is the SIGKILL fallback. It must come
    # before Postgres is recreated below: the app needs its database to finish
    # those writes, and with Postgres force-removed under it the shutdown
    # fails. `docker rm -f` alone is SIGKILL and skips all of it. On a first
    # boot there is no container, hence `|| true`.
    "docker stop -t 9 automation-service >/dev/null 2>&1 || true",
    # Postgres is stopped first (the image's STOPSIGNAL is SIGINT: a fast
    # shutdown with a checkpoint), so the new container starts clean instead
    # of running WAL crash recovery after a SIGKILL.
    "docker stop -t 30 automation-service-postgres >/dev/null 2>&1 || true",
    "docker rm -f automation-service-postgres >/dev/null 2>&1 || true",
    "docker run -d --name automation-service-postgres --restart unless-stopped --network host -v /data/automation-service-postgres/pgdata:/var/lib/postgresql/data -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=\"$POSTGRES_PASSWORD\" -e POSTGRES_DB=automation postgres:16-alpine",
    "for _ in $(seq 1 30); do docker exec automation-service-postgres pg_isready -U postgres >/dev/null 2>&1 && break; sleep 5; done",
    "docker rm -f automation-service >/dev/null 2>&1 || true",
    # Token verification is auth-service's (decision 21, meta#80); this service
    # holds no Clerk verification key.
    "docker run -d --name automation-service --restart unless-stopped --network host -e PORT=${var.automation_service_port} -e DATABASE_URL=\"postgres://postgres:$POSTGRES_PASSWORD@localhost:5432/automation\" -e NAVIGATION_SERVICE_URL=http://localhost:${data.terraform_remote_state.navigation_service.outputs.navigation_service_port}/api/navigation/v1 -e AGENT_SERVICE_URL=http://localhost:${data.terraform_remote_state.agent_service.outputs.agent_service_port}/api/agent/v1 -e FLEET_SERVICE_URL=http://localhost:${data.terraform_remote_state.fleet_service.outputs.fleet_service_port}/api/fleet/v1 -e MINING_SHIP_SYMBOL=${var.mining_ship_symbol} -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e AUTH_INTROSPECTION_URL=${data.terraform_remote_state.auth_service.outputs.auth_introspection_url} -e AUTH_INTROSPECTION_SECRET=\"$AUTH_INTROSPECTION_SECRET\" -e AUTH_M2M_TOKEN_URL=${data.terraform_remote_state.auth_service.outputs.auth_m2m_token_url} -e AUTH_M2M_CALLER_SECRET=\"$AUTH_M2M_CALLER_SECRET\" ${var.automation_service_image}",
    # `docker run -d` returning 0 only means the container was created. From
    # meta#80 step 8 the image refuses to start on a missing or bad
    # AUTH_INTROSPECTION_* value. With --restart unless-stopped such a
    # container is restarted over and over, and Docker reports
    # State.Running=true for most of that loop, so a running check passes a
    # crash-looping container. Poll /api/automation/health for up to ~90 s
    # instead, then a non-zero exit so the SSM command is reported as Failed
    # rather than Success. Same check as fleet-service's bootstrap.
    "AUTOMATION_HEALTHY=no",
    "_attempt=0",
    "while [ \"$_attempt\" -lt 30 ]; do",
    "  _attempt=$((_attempt + 1))",
    "  if curl -fs -o /dev/null --max-time 2 http://127.0.0.1:${var.automation_service_port}/api/automation/health; then",
    "    AUTOMATION_HEALTHY=yes",
    "    break",
    "  fi",
    "  sleep 3",
    "done",
    "if [ \"$AUTOMATION_HEALTHY\" != yes ]; then",
    "  echo 'FATAL: automation-service did not answer GET /api/automation/health on 127.0.0.1:${var.automation_service_port} within ~90s of docker run. Container state, restart count and the last 50 log lines follow.' >&2",
    "  docker inspect -f 'state={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} restarts={{.RestartCount}} exit={{.State.ExitCode}} err={{.State.Error}}' automation-service >&2 2>/dev/null || echo 'no such container' >&2",
    "  docker logs --tail 50 automation-service >&2 2>&1 || true",
    "  exit 1",
    "fi",
    "echo \"automation-service is running on port ${var.automation_service_port}.\"",
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
