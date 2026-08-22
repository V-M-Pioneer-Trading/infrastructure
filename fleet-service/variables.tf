variable "aws_region" {
  description = "AWS region for fleet-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate and agent-service/terraform.tfstate."
  type        = string
}

variable "ec2_instance_id" {
  description = "Shared EC2 instance ID where fleet-service is provisioned."
  type        = string
}

variable "fleet_service_port" {
  description = "Port exposed by fleet-service on shared EC2 host."
  type        = number
  default     = 3001
}

variable "fleet_service_image" {
  description = "Container image (with tag) used for fleet-service."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/fleet-service:latest"
}

variable "cors_allowed_origin" {
  description = "Origin allowed to call fleet-service via CORS in production."
  type        = string
  default     = "https://spacetraders.radomskyi.com"
}

# No default: this is the spacetraders Clerk instance's RS256 public key
# (PEM/SPKI), fetched from its JWKS endpoint — not a secret, but nothing
# guesses it, so it must be supplied explicitly at apply time.
variable "clerk_jwt_key" {
  description = "Clerk RS256 public key (PEM/SPKI) fleet-service uses to verify session JWTs."
  type        = string
  sensitive   = true
}

variable "clerk_issuer" {
  description = "Expected `iss` claim on Clerk session JWTs — narrows misconfiguration, verification itself relies on the key above."
  type        = string
  default     = "https://uncommon-crayfish-6401.clerk.accounts.dev"
}
