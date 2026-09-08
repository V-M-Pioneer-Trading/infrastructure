variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name (dev, prod)."
  type        = string
  default     = "dev"
}

variable "container_image" {
  description = "Container image URI with tag."
  type        = string
  default     = "public.ecr.aws/docker/library/busybox:latest"
}

variable "container_port" {
  description = "Application container port."
  type        = number
  default     = 8080
}

variable "cpu" {
  description = "Fargate CPU units."
  type        = number
  default     = 512
}

variable "memory" {
  description = "Fargate memory in MiB."
  type        = number
  default     = 1024
}

variable "desired_count" {
  description = "Desired task count."
  type        = number
  default     = 1
}

variable "sqlite_db_path" {
  description = "SQLite file path used by application."
  type        = string
  default     = "/data/nav.db"
}

variable "vpc_id" {
  description = "Target VPC ID. Empty means account default VPC."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Target subnets. Empty means all subnets in resolved VPC."
  type        = list(string)
  default     = []
}

variable "assign_public_ip" {
  description = "Assign public IP to Fargate tasks."
  type        = bool
  default     = true
}

variable "ingress_cidr_blocks" {
  description = "CIDRs allowed inbound to service port."
  type        = list(string)
  default     = []
}

variable "ingress_security_group_ids" {
  description = "Security groups allowed inbound to service port."
  type        = list(string)
  default     = []
}

