variable "aws_region" {
  description = "AWS region for agent-service infrastructure."
  type        = string
  default     = "eu-central-1"
}

variable "state_bucket" {
  description = "S3 bucket that stores Terraform state, including personal/terraform.tfstate."
  type        = string
}

variable "ec2_instance_id" {
  description = "Shared EC2 instance ID where agent-service and its MySQL container are provisioned."
  type        = string
}

variable "agent_service_port" {
  description = "Port exposed by agent-service on shared EC2 host. Fixed at 80 to match the binary's hardcoded listen port."
  type        = number
  default     = 80
}

variable "agent_service_image" {
  description = "Container image (with tag) used for agent-service."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/agent-service:latest"
}

variable "agent_service_mysql_data_volume_size_gb" {
  description = "Size in GiB for encrypted EBS volume mounted for agent-service's MySQL data."
  type        = number
  default     = 10
}

variable "cors_allowed_origin" {
  description = "Origin allowed to call agent-service via CORS in production."
  type        = string
  default     = "https://spacetraders.radomskyi.com"
}

variable "gateway_image" {
  description = "Container image (with tag) used for st-gateway."
  type        = string
  default     = "ghcr.io/v-m-pioneer-trading/st-gateway:latest"
}

variable "gateway_port" {
  description = "Port st-gateway listens on."
  type        = number
  default     = 3002
}
