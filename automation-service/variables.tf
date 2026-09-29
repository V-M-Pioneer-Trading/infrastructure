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

# No sensible default — the mining loop is tracer-bullet single-ship (meta#9),
# so this pins which ship in the fleet actually runs it in prod.
variable "mining_ship_symbol" {
  description = "SpaceTraders ship symbol automation-service's mining autopilot drives."
  type        = string
}

# No default: a real Clerk Machine's Secret Key (auth-design.md decision
# 19), which only Clerk mints — a genuine bearer credential. Lets
# automation-service mint its own M2M token to call agent/fleet-service, since
# it has no human Clerk session to present the way command-interface does.
variable "clerk_m2m_secret_key" {
  description = "Secret Key for the Clerk Machine representing automation-service, used to mint its outbound M2M token."
  type        = string
  sensitive   = true
}
