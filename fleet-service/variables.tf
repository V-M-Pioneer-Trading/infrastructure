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
