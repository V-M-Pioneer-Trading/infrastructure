data "aws_vpc" "target" {
  id      = var.vpc_id != "" ? var.vpc_id : null
  default = var.vpc_id == ""
}

data "aws_subnets" "target" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.target.id]
  }
}

locals {
  resolved_vpc_id     = data.aws_vpc.target.id
  resolved_subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.target.ids
}

module "navigation_service" {
  source = "../../modules/ecs-service-with-efs"

  project_name = "navigation-service"
  service_name = "navigation-service"
  environment  = var.environment

  container_image   = var.container_image
  container_port    = var.container_port
  cpu               = var.cpu
  memory            = var.memory
  desired_count     = var.desired_count
  sqlite_mount_path = "/data"

  vpc_id           = local.resolved_vpc_id
  subnet_ids       = local.resolved_subnet_ids
  assign_public_ip = var.assign_public_ip

  ingress_cidr_blocks        = var.ingress_cidr_blocks
  ingress_security_group_ids = var.ingress_security_group_ids

  environment_variables = {
    SPRING_PROFILES_ACTIVE = var.environment
    SQLITE_DB_PATH         = var.sqlite_db_path
    SERVER_PORT            = tostring(var.container_port)
  }
}

