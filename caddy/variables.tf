variable "aws_region" {
  description = "AWS region for the Caddy edge stack."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate and each backend service's state."
  type        = string
}

variable "ec2_instance_id" {
  description = "Shared EC2 instance ID where the Caddy edge proxy runs alongside the backend containers."
  type        = string
}

variable "backend_domain" {
  description = "Public DNS name CloudFront uses for the HTTPS backend origin, and the name Caddy issues its certificate for."
  type        = string
  default     = "spacetraders-backend.radomskyi.com"
}

variable "acme_email" {
  description = "Contact email for the ACME (Let's Encrypt) account Caddy registers."
  type        = string
  default     = "maxradomskyy@gmail.com"
}

variable "origin_verify_param_name" {
  description = "SSM Parameter Store name (SecureString) holding the shared X-Origin-Verify secret. Created out-of-band; read by Caddy at container start and by the CloudFront stack for the origin custom header."
  type        = string
  default     = "spacetraders-origin-verify"
}
