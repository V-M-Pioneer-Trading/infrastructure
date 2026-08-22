variable "aws_region" {
  description = "AWS region for automation-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate, navigation-service/terraform.tfstate, agent-service/terraform.tfstate and fleet-service/terraform.tfstate."
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

# No default: this is the spacetraders Clerk instance's RS256 public key
# (PEM/SPKI), fetched from its JWKS endpoint — not a secret, but nothing
# guesses it, so it must be supplied explicitly at apply time.
variable "clerk_jwt_key" {
  description = "Clerk RS256 public key (PEM/SPKI) automation-service uses to verify session JWTs."
  type        = string
  sensitive   = true
}

variable "clerk_issuer" {
  description = "Expected `iss` claim on Clerk session JWTs — narrows misconfiguration, verification itself relies on the key above."
  type        = string
  default     = "https://uncommon-crayfish-6401.clerk.accounts.dev"
}
