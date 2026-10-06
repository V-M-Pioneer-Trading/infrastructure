variable "aws_region" {
  description = "AWS region for automation-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate, navigation-service/terraform.tfstate, agent-service/terraform.tfstate, fleet-service/terraform.tfstate and auth-service/terraform.tfstate."
  type        = string
}

variable "ec2_instance_id" {
  description = "Shared EC2 instance ID where automation-service and its Postgres container are provisioned."
  type        = string
}

variable "automation_service_port" {
  description = "Port exposed by automation-service on shared EC2 host."
  type        = number
  default     = 3003
}

variable "automation_service_image" {
  description = "Container image (with tag) used for automation-service."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/automation-service:latest"
}

variable "automation_service_postgres_data_volume_size_gb" {
  description = "Size in GiB for encrypted EBS volume mounted for automation-service's Postgres data."
  type        = number
  default     = 10
}

variable "cors_allowed_origin" {
  description = "Origin allowed to call automation-service via CORS in production."
  type        = string
  default     = "https://spacetraders.radomskyi.com"
}

# automation-service#47. Not a secret: only the body shape. The URL itself is
# the optional SSM SecureString automation-service-anomaly-webhook-url, read on
# the host; this is passed to the container only when that parameter exists.
# telegram needs an automation-service image with Telegram support
# (automation-service#50); an older image refuses to start on it.
variable "anomaly_webhook_format" {
  description = "Body format automation-service posts anomalies in: generic or telegram."
  type        = string
  default     = "generic"

  validation {
    condition     = contains(["generic", "telegram"], var.anomaly_webhook_format)
    error_message = "anomaly_webhook_format must be one of generic, telegram."
  }
}

# automation-service#47. Not a secret: which Telegram chat the bot posts to
# (the bot token is in the SSM URL). Passed as ANOMALY_TELEGRAM_CHAT_ID only
# when the webhook parameter exists and the format is telegram. Required with
# telegram and refused without it, as the service itself does, so a mismatch
# fails at plan time rather than as a container that will not start.
variable "anomaly_telegram_chat_id" {
  description = "Telegram chat id for anomaly pages: a numeric id (negative for groups) or @channelusername. Required iff anomaly_webhook_format is telegram."
  type        = string
  default     = ""

  validation {
    condition     = var.anomaly_telegram_chat_id == "" || can(regex("^(-?[0-9]{1,20}|@[A-Za-z0-9_]{5,32})$", var.anomaly_telegram_chat_id))
    error_message = "anomaly_telegram_chat_id must be empty, a numeric chat id (optionally negative), or @channelusername (5-32 of A-Z a-z 0-9 _)."
  }

  validation {
    condition     = (var.anomaly_webhook_format == "telegram") == (var.anomaly_telegram_chat_id != "")
    error_message = "anomaly_telegram_chat_id is required when anomaly_webhook_format is telegram, and must be empty otherwise."
  }
}

# No sensible default — the mining loop is tracer-bullet single-ship (meta#9),
# so this pins which ship in the fleet actually runs it in prod.
variable "mining_ship_symbol" {
  description = "SpaceTraders ship symbol automation-service's mining autopilot drives."
  type        = string
}
