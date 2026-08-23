variable "aws_region" {
  description = "AWS region for auth-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate."
  type        = string
}

variable "ec2_instance_id" {
  description = "Shared EC2 instance ID where the auth-service container is provisioned."
  type        = string
}

# 3005: agent-service (80), navigation-service (8080), fleet-service (3001),
# st-gateway (3002), automation-service (3003) and ai-service (3004) are
# already claimed on this --network host EC2 instance — see each service's
# own stack. Not yet reachable from anywhere (no Caddy route, no CloudFront
# behavior — that's increment 3 Stage 4); this only needs to not collide.
variable "auth_service_port" {
  description = "Port auth-service listens on on the shared EC2 host."
  type        = number
  default     = 3005
}

variable "auth_service_image" {
  description = "Container image (with tag) used for auth-service."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/auth-service:latest"
}

# Deliberately small — auth-design.md decision 6/"New repository: auth-service"
# describes the persisted state as "a handful of rows plus a registration
# history," nothing like the other services' data volumes.
variable "auth_service_data_volume_size_gb" {
  description = "Size in GiB for the encrypted EBS volume holding auth-service's SQLite file."
  type        = number
  default     = 1
}

variable "cors_allowed_origin" {
  description = "Origin allowed to call auth-service's public routes via CORS in production."
  type        = string
  default     = "https://spacetraders.radomskyi.com"
}

# No default: this is the spacetraders Clerk instance's RS256 public key
# (PEM/SPKI) — not a secret, but nothing guesses it, so it must be supplied
# explicitly at apply time. Same value every other service's stack already
# takes as clerk_jwt_key.
variable "clerk_jwt_key" {
  description = "Clerk RS256 public key (PEM/SPKI) auth-service uses to verify session JWTs on its two agent:reset routes."
  type        = string
  sensitive   = true
}

variable "clerk_issuer" {
  description = "Expected `iss` claim on Clerk session JWTs — narrows misconfiguration, verification itself relies on the key above."
  type        = string
  default     = "https://uncommon-crayfish-6401.clerk.accounts.dev"
}
