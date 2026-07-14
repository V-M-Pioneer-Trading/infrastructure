variable "aws_region" {
  description = "AWS region for navigation-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate."
  type        = string
}

variable "navigation_service_port" {
  description = "Port exposed by navigation-service on shared EC2 host."
  type        = number
  default     = 8080
}
