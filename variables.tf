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

variable "navigation_service_client_cidr_ipv4" {
  description = "Client IPv4 CIDR allowed to reach navigation-service port on shared EC2 security group."
  type        = string
  default     = "0.0.0.0/0"
}

variable "navigation_service_image" {
  description = "Container image (with tag) used for navigation-service."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/navigation-service:latest"
}

variable "navigation_service_ghcr_username" {
  description = "GitHub username used to authenticate to ghcr.io when pulling the (private) navigation-service image. The token itself lives in SSM Parameter Store (navigation-service-ghcr-pat), created out-of-band."
  type        = string
  default     = "mradomsky"
}

variable "navigation_service_data_volume_size_gb" {
  description = "Size in GiB for encrypted EBS volume mounted at /data."
  type        = number
  default     = 10
}
