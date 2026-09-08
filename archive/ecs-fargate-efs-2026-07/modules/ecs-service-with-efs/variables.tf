variable "project_name" {
  description = "Project name used in resource names."
  type        = string
}

variable "service_name" {
  description = "Service name used in resource names."
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)."
  type        = string
}

variable "container_image" {
  description = "Container image URI with tag."
  type        = string
}

variable "container_port" {
  description = "Container port."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Fargate task CPU units."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate task memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Number of desired ECS tasks."
  type        = number
  default     = 1
}

variable "vpc_id" {
  description = "Target VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets used by ECS tasks and EFS mount targets."
  type        = list(string)
}

variable "assign_public_ip" {
  description = "Assign public IP to ECS tasks."
  type        = bool
  default     = false
}

variable "sqlite_mount_path" {
  description = "Container mount path for persistent storage."
  type        = string
  default     = "/data"
}

variable "environment_variables" {
  description = "Environment variables injected to container."
  type        = map(string)
  default     = {}
}

variable "task_role_policy_json" {
  description = "Optional JSON IAM policy attached to task role."
  type        = string
  default     = ""
}

variable "efs_throughput_mode" {
  description = "EFS throughput mode."
  type        = string
  default     = "bursting"
}

variable "ingress_cidr_blocks" {
  description = "CIDRs allowed to access container port."
  type        = list(string)
  default     = []
}

variable "ingress_security_group_ids" {
  description = "Security groups allowed to access container port."
  type        = list(string)
  default     = []
}

