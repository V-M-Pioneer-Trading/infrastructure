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

# meta#80 step 3 / decision 21. A SECOND, INDEPENDENT secret — deliberately a
# separate random_password resource rather than a reuse of the one above, so
# the two values can never coincide. This one is handed to every calling
# service (fleet, automation, navigation, agent, st-gateway) in steps 4-9;
# `auth_service_shared_secret` above is the vault key and stays with
# st-gateway alone. Reusing the vault's secret here would hand four more
# stacks the key to GET /auth/v1/token — see auth-design.md decision 9's
# 2026-09-20 note, which is why this separation is load-bearing.
# auth-service refuses to start if the two hold the same value.
resource "random_password" "auth_introspection_secret" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "auth_introspection_secret" {
  name  = "auth-service-introspection-secret"
  type  = "SecureString"
  value = random_password.auth_introspection_secret.result
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
          aws_ssm_parameter.auth_introspection_secret.arn,
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
  authnet_subnet          = "172.28.0.0/24"
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
    # containers, so auth-service's IP is guarded explicitly in two chains.
    # Everything below was verified live against the real host (2026-08-23).
    # An earlier subnet-wide version of these rules caused a production
    # outage; the reasoning for the current shape is recorded here so it
    # doesn't get "simplified" back into one.
    #
    # SCOPE: both jumps match auth-service's IP alone, NOT the whole
    # ${local.authnet_subnet}. Subnet-wide is the intuitive way to write this
    # and it is wrong — the subnet also holds st-gateway's DNAT'd published
    # port and Caddy's public :443, so a subnet-wide guard drops CloudFront's
    # inbound HTTPS to Caddy (100% of public ingress) along with replies bound
    # for any authnet member. auth-service is the only thing that must be
    # unreachable from off-bridge; guard exactly that and nothing else.
    #
    # 1. DOCKER-USER (FORWARD) — filters what the bridge routes toward
    #    auth-service. br_netfilter is enabled here (Docker needs it for
    #    NAT/port publishing), so even same-bridge container-to-container
    #    traffic transits DOCKER-USER; the -s ${local.authnet_subnet}
    #    exception is what keeps st-gateway/Caddy -> auth-service working.
    #    The conntrack exception is required for auth-service's own outbound
    #    replies: without it, DNS answers and SpaceTraders API responses
    #    coming back to the bridge are dropped. That exact bug silently broke
    #    st-gateway's DNS resolution — nothing could reach the real game API —
    #    while every /health check kept returning 200, so it went unnoticed.
    #
    # 2. OUTPUT — the piece DOCKER-USER cannot cover: a host process (or,
    #    equivalently, a --network host container; all four share the host's
    #    netns, verified by comparing /proc/<pid>/ns/net) addressing a bridge
    #    IP directly never transits FORWARD/DOCKER-USER on this kernel. Only
    #    OUTPUT sees it. Its conntrack exception is equally load-bearing:
    #    replies from host-network services back to an authnet container are
    #    locally-generated packets, and dropping them breaks Caddy ->
    #    navigation/agent/fleet/automation completely.
    #    Chain name capped at 28 chars — iptables' own limit, hit once
    #    (auth-service-authnet-output-guard, 34 chars, rejected outright).
    #
    # Both custom chains are flushed and rebuilt every run, keeping this
    # idempotent without stacking duplicate jump entries. The two -D lines
    # strip the legacy subnet-wide jumps from hosts bootstrapped before the
    # rescope; they no-op once those are gone.
    "iptables -D DOCKER-USER -d ${local.authnet_subnet} -j auth-service-authnet-guard 2>/dev/null || true",
    "iptables -D OUTPUT -d ${local.authnet_subnet} -j authnet-out-guard 2>/dev/null || true",
    "iptables -N auth-service-authnet-guard 2>/dev/null || true",
    "iptables -F auth-service-authnet-guard",
    "iptables -A auth-service-authnet-guard -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN",
    "iptables -A auth-service-authnet-guard -s ${local.authnet_subnet} -j RETURN",
    "iptables -A auth-service-authnet-guard -j DROP",
    "iptables -C DOCKER-USER -d ${local.authnet_auth_service_ip}/32 -j auth-service-authnet-guard 2>/dev/null || iptables -I DOCKER-USER -d ${local.authnet_auth_service_ip}/32 -j auth-service-authnet-guard",
    "iptables -N authnet-out-guard 2>/dev/null || true",
    "iptables -F authnet-out-guard",
    "iptables -A authnet-out-guard -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN",
    # meta#80 step 3 / decision 21: the ONE new rule. It lets a host process —
    # and therefore any --network host container: fleet, automation,
    # navigation, agent — open a NEW connection to auth-service's listener, so
    # they can call POST /auth/v1/introspect. Everything else addressed to
    # ${local.authnet_auth_service_ip} still falls through to the DROP below.
    #
    # It is a permitting rule inserted before the DROP, which is why it cannot
    # reproduce the August/2026-08-23 outages: those came from an over-broad
    # DROP, and a RETURN can only widen. auth-service-authnet-guard is NOT
    # touched — st-gateway and Caddy reach auth-service over bridge DNS and
    # that chain already returns for authnet sources.
    #
    # The accepted, temporary cost (auth-design.md decision 9's 2026-09-20
    # note, owner's decision): this is a single process on a single port, so
    # GET /auth/v1/token becomes network-reachable from those four services
    # too. It stays guarded by AUTH_SERVICE_SHARED_SECRET, which no container
    # but st-gateway and auth-service ever receives. That is what makes the
    # SEPARATE introspection secret above load-bearing. The downgrade ends
    # when the vault moves into st-gateway and the token route disappears.
    "iptables -A authnet-out-guard -p tcp --dport ${var.auth_service_port} -j RETURN",
    "iptables -A authnet-out-guard -j DROP",
    "iptables -C OUTPUT -d ${local.authnet_auth_service_ip}/32 -j authnet-out-guard 2>/dev/null || iptables -I OUTPUT -d ${local.authnet_auth_service_ip}/32 -j authnet-out-guard",
    # ------------------------------------------------------------------
    # Secret reads. EVERY read happens BEFORE `docker rm -f`, and a failed
    # read aborts the script, so a running auth-service is left untouched
    # rather than replaced by one holding an empty secret.
    #
    # Why the retry loop: `aws_iam_role_policy.shared_ec2_auth_service_ssm_parameters`
    # gains this stack's new parameter ARN in the same apply that publishes
    # the new document version, and IAM is eventually consistent. For a short
    # window the instance role's cached policy can still deny the read. The
    # AWS CLI prints nothing to stdout on AccessDenied (and `None` when a
    # parameter resolves to nothing), so an unguarded `$(...)` yields an EMPTY
    # string — and an auth-service started with an empty
    # AUTH_INTROSPECTION_SECRET answers 401 to every caller, which looks
    # exactly like a firewall problem. `depends_on` on the SSM document below
    # orders the policy before the document version; this loop covers the
    # propagation delay that ordering cannot.
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
    "  echo \"FATAL: SSM parameter $_param_name read back empty after ~60s. Most likely the instance role is not yet allowed to read it (IAM eventual consistency) or the parameter does not exist. Refusing to restart auth-service with an empty secret; the running container is untouched.\" >&2",
    "  return 1",
    "}",
    "AUTH_SERVICE_SHARED_SECRET=$(read_secure_parameter ${aws_ssm_parameter.auth_service_shared_secret.name}) || exit 1",
    "AUTH_INTROSPECTION_SECRET=$(read_secure_parameter ${aws_ssm_parameter.auth_introspection_secret.name}) || exit 1",
    "CLERK_JWT_KEY=$(read_secure_parameter ${aws_ssm_parameter.clerk_jwt_key.name}) || exit 1",
    "[ -n \"$AUTH_SERVICE_SHARED_SECRET\" ] || { echo 'FATAL: AUTH_SERVICE_SHARED_SECRET is empty.' >&2; exit 1; }",
    "[ -n \"$AUTH_INTROSPECTION_SECRET\" ] || { echo 'FATAL: AUTH_INTROSPECTION_SECRET is empty.' >&2; exit 1; }",
    "[ -n \"$CLERK_JWT_KEY\" ] || { echo 'FATAL: CLERK_JWT_KEY is empty.' >&2; exit 1; }",
    "echo 'all three parameters read back non-empty.'",
    # ------------------------------------------------------------------
    # The loopback port must be free, or free because WE hold it. Checked
    # BEFORE `docker rm -f`: from this apply onward the `docker run` below
    # binds 127.0.0.1:${var.auth_service_port}, and a bind failure after the
    # container has already been removed leaves the vault down. If anything
    # other than the current auth-service container holds the port, stop here
    # with auth-service still running.
    "PORT_HELD=no",
    "if ss -ltn 2>/dev/null | grep -qE \"127\\\\.0\\\\.0\\\\.1:${var.auth_service_port}[[:space:]]\"; then PORT_HELD=yes; fi",
    "PORT_IS_OURS=no",
    "if docker port auth-service 2>/dev/null | grep -qE \"127\\\\.0\\\\.0\\\\.1:${var.auth_service_port}\\$\"; then PORT_IS_OURS=yes; fi",
    "if [ \"$PORT_HELD\" = yes ] && [ \"$PORT_IS_OURS\" = no ]; then",
    "  echo 'FATAL: 127.0.0.1:${var.auth_service_port} is already held by something that is not the current auth-service container. Removing auth-service now would leave the vault down when docker run fails to bind. Listener follows; free the port and re-run the association.' >&2",
    "  ss -ltnp 2>/dev/null | grep -w ${var.auth_service_port} >&2 || true",
    "  exit 1",
    "fi",
    # ------------------------------------------------------------------
    # Image digest before and after the pull. The tag is deliberately NOT
    # pinned — `:latest` is how every stack on this host deploys — so the
    # digests are echoed instead, and the SSM command output then says
    # whether this run changed the image. The PR runbook's pre-apply step
    # compares the running digest with the registry's `:latest` beforehand,
    # so the change is known before the apply rather than after.
    "IMAGE_DIGEST_BEFORE=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.auth_service_image} 2>/dev/null || true)",
    "echo \"auth-service image digest before pull: $IMAGE_DIGEST_BEFORE\"",
    "docker pull ${var.auth_service_image}",
    "IMAGE_DIGEST_AFTER=$(docker image inspect --format '{{join .RepoDigests \",\"}}' ${var.auth_service_image} 2>/dev/null || true)",
    "echo \"auth-service image digest after pull:  $IMAGE_DIGEST_AFTER\"",
    "if [ \"$IMAGE_DIGEST_BEFORE\" != \"$IMAGE_DIGEST_AFTER\" ]; then",
    "  echo 'NOTE: the pull changed the image; this run deploys a different build than the one that was running.'",
    "else",
    "  echo 'NOTE: the pull did not change the image.'",
    "fi",
    "docker rm -f auth-service >/dev/null 2>&1 || true",
    # -p 127.0.0.1:<port>:<port> (meta#80 step 3): loopback ONLY, exactly the
    # form st-gateway already uses one stack over. The four --network host
    # services then call http://localhost:${var.auth_service_port}/auth/v1/introspect,
    # the same address shape they already use for st-gateway, with no
    # knowledge of the bridge's IP plan. Chosen over handing them
    # http://${local.authnet_auth_service_ip}:${var.auth_service_port} because
    # the 127.0.0.1 bind keeps the listener off eth0 and every other external
    # interface at the kernel level — the security group is then not the only
    # thing standing between this port and the internet — and because it does
    # not spread the hand-coordinated fixed-IP literal into four more stacks.
    #
    # Why filter OUTPUT still sees this traffic, whichever path Docker takes.
    # Docker publishes a port in two ways and BOTH end up host-originated to
    # ${local.authnet_auth_service_ip}, so the authnet-out-guard jump on
    # OUTPUT — not the publish — is what makes the route reachable:
    #   * DNAT path: the `nat OUTPUT` DOCKER rule rewrites the destination to
    #     ${local.authnet_auth_service_ip}:${var.auth_service_port} before
    #     `filter OUTPUT` runs, so filter OUTPUT matches the bridge IP.
    #   * userland-proxy path: docker-proxy accepts on 127.0.0.1 and opens its
    #     OWN connection to ${local.authnet_auth_service_ip}:${var.auth_service_port}
    #     from the host netns — again a locally-generated packet through
    #     filter OUTPUT.
    # Either way it is FORWARD/DOCKER-USER that never sees it, which is the
    # whole reason the OUTPUT chain exists. `docker port auth-service` plus
    # `iptables -t nat -S DOCKER` say which path this host is on.
    #
    # Why this is not reachable from off-host: three independent reasons, and
    # the publish alone is only the first.
    #   1. The bind is 127.0.0.1, so the kernel never accepts a packet for
    #      this port on eth0 — there is no DNAT from an external interface to
    #      create in the first place.
    #   2. If net.ipv4.conf.all.route_localnet were ever set to 1, a remote
    #      packet addressed to 127.0.0.1 could be routed in; it would then
    #      transit FORWARD -> DOCKER-USER -> auth-service-authnet-guard, whose
    #      source is not ${local.authnet_subnet} and is therefore DROPped.
    #   3. The instance security group allows 443 to Caddy only, and this PR
    #      adds no ingress rule.
    # The runbook checks `sysctl net.ipv4.conf.all.route_localnet` so reason 2
    # is observed rather than assumed.
    #
    # The SQLite data volume mount is unchanged.
    "docker run -d --name auth-service --restart unless-stopped --network authnet --ip ${local.authnet_auth_service_ip} -p 127.0.0.1:${var.auth_service_port}:${var.auth_service_port} -v ${local.data_mount}:/data -e SQLITE_DB_PATH=/data/auth.db -e PORT=${var.auth_service_port} -e ST_GATEWAY_URL=http://st-gateway:${local.st_gateway_port} -e CORS_ALLOWED_ORIGIN=${var.cors_allowed_origin} -e CLERK_JWT_KEY=\"$CLERK_JWT_KEY\" -e CLERK_ISSUER=${var.clerk_issuer} -e AUTH_SERVICE_SHARED_SECRET=\"$AUTH_SERVICE_SHARED_SECRET\" -e AUTH_INTROSPECTION_SECRET=\"$AUTH_INTROSPECTION_SECRET\" ${var.auth_service_image}",
    # `docker run -d` returning 0 only means the container was created. A bind
    # failure on 127.0.0.1:${var.auth_service_port}, or a config the service
    # refuses to start with, leaves the vault DOWN. With --restart
    # unless-stopped such a container is restarted over and over, and Docker
    # reports State.Running=true for most of that loop, so a running check
    # passes a crash-looping container. Poll /health through the loopback
    # publish for up to ~90 s instead (which also proves the publish), then
    # a non-zero exit so the SSM command is reported as Failed rather than
    # Success. (`set -euo pipefail` is the first runCommand line, but this
    # check is explicit so the failure has a readable message and does not
    # depend on it.)
    "AUTH_HEALTHY=no",
    "_attempt=0",
    "while [ \"$_attempt\" -lt 30 ]; do",
    "  _attempt=$((_attempt + 1))",
    "  if curl -fs -o /dev/null --max-time 2 http://127.0.0.1:${var.auth_service_port}/health; then",
    "    AUTH_HEALTHY=yes",
    "    break",
    "  fi",
    "  sleep 3",
    "done",
    "if [ \"$AUTH_HEALTHY\" != yes ]; then",
    "  echo 'FATAL: auth-service did not answer GET /health on 127.0.0.1:${var.auth_service_port} within ~90s of docker run. The credential vault and the introspection route are DOWN on this host. Container state, restart count and the last 50 log lines follow.' >&2",
    "  docker inspect -f 'state={{.State.Status}} running={{.State.Running}} restarting={{.State.Restarting}} restarts={{.RestartCount}} exit={{.State.ExitCode}} err={{.State.Error}}' auth-service >&2 2>/dev/null || echo 'no such container' >&2",
    "  docker logs --tail 50 auth-service >&2 2>&1 || true",
    "  exit 1",
    "fi",
    "echo \"auth-service is running and bound to 127.0.0.1:${var.auth_service_port}.\"",
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

  # The bootstrap reads auth-service-introspection-secret with the shared EC2
  # role. Without this edge Terraform is free to publish the new document
  # version — which the association immediately re-runs — before the policy
  # that grants GetParameter on the new ARN exists, and the read comes back
  # empty: auth-service then starts with an empty AUTH_INTROSPECTION_SECRET
  # and answers 401 to every caller, indistinguishable from a firewall
  # problem. Ordering fixes the create-order race; the retry loop in the
  # script covers IAM's eventual consistency, which ordering cannot.
  depends_on = [aws_iam_role_policy.shared_ec2_auth_service_ssm_parameters]
}

resource "aws_ssm_association" "auth_service_bootstrap" {
  name = aws_ssm_document.auth_service_bootstrap.name

  targets {
    key    = "InstanceIds"
    values = [var.ec2_instance_id]
  }

  # Same reason as the document above: the association is what actually runs
  # the script on the host, so it must not fire before the policy grant.
  depends_on = [
    aws_volume_attachment.auth_service_data,
    aws_iam_role_policy.shared_ec2_auth_service_ssm_parameters,
  ]
}
