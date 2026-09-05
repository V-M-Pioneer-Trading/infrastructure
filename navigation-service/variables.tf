variable "aws_region" {
  description = "AWS region for navigation-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate."
  type        = string
}

variable "ec2_instance_id" {
  description = "Shared EC2 instance ID where navigation-service container is provisioned."
  type        = string
}

variable "navigation_service_port" {
  description = "Port exposed by navigation-service on shared EC2 host."
  type        = number
  default     = 8080
}

variable "navigation_service_image" {
  description = "Container image (with tag) used for navigation-service."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/navigation-service:latest"
}

variable "navigation_service_data_volume_size_gb" {
  description = "Size in GiB for encrypted EBS volume mounted at /data."
  type        = number
  default     = 10
}

variable "cors_allowed_origin" {
  description = "Origin allowed to call navigation-service via CORS in production."
  type        = string
  default     = "https://spacetraders.radomskyi.com"
}

variable "clerk_jwt_key" {
  description = "Clerk RS256 public key (PEM/SPKI) navigation-service uses to verify session JWTs."
  type        = string
  sensitive   = true
}

variable "clerk_issuer" {
  description = "Expected `iss` claim on Clerk session JWTs — narrows misconfiguration, verification itself relies on the key above."
  type        = string
  default     = "https://uncommon-crayfish-6401.clerk.accounts.dev"
}
