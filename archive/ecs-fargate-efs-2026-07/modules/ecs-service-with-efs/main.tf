locals {
  name_prefix = "${var.project_name}-${var.service_name}-${var.environment}"
}

resource "aws_efs_file_system" "data" {
  performance_mode = "generalPurpose"
  throughput_mode  = var.efs_throughput_mode
  encrypted        = true

  tags = {
    Name = "${local.name_prefix}-efs"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_access_point" "data" {
  file_system_id = aws_efs_file_system.data.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = var.sqlite_mount_path
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "755"
    }
  }

  tags = {
    Name = "${local.name_prefix}-ap"
  }
}

resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-efs"
  description = "Allow NFS from ECS tasks"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS from ECS tasks"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.task.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-efs"
  }
}

resource "aws_efs_mount_target" "data" {
  for_each = toset(var.subnet_ids)

  file_system_id  = aws_efs_file_system.data.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_iam_role" "execution" {
  name = "${local.name_prefix}-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "${local.name_prefix}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "task_extra" {
  count = var.task_role_policy_json != "" ? 1 : 0

  name   = "${local.name_prefix}-task-extra"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_task_definition" "service" {
  family                   = local.name_prefix
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  volume {
    name = "data"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.data.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.data.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = var.service_name
      image     = var.container_image
      essential = true

      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]

      environment = [
        for k, v in var.environment_variables : { name = k, value = v }
      ]

      mountPoints = [{
        sourceVolume  = "data"
        containerPath = var.sqlite_mount_path
        readOnly      = false
      }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  lifecycle {
    ignore_changes = [container_definitions]
  }
}

data "aws_region" "current" {}

resource "aws_security_group" "task" {
  name        = "${local.name_prefix}-task"
  description = "ECS task ingress and egress"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.ingress_cidr_blocks) > 0 ? [1] : []
    content {
      description = "Container port from CIDRs"
      from_port   = var.container_port
      to_port     = var.container_port
      protocol    = "tcp"
      cidr_blocks = var.ingress_cidr_blocks
    }
  }

  dynamic "ingress" {
    for_each = length(var.ingress_security_group_ids) > 0 ? [1] : []
    content {
      description     = "Container port from security groups"
      from_port       = var.container_port
      to_port         = var.container_port
      protocol        = "tcp"
      security_groups = var.ingress_security_group_ids
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-task"
  }
}

resource "aws_ecs_service" "service" {
  name            = var.service_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.service.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = var.assign_public_ip
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  depends_on = [aws_efs_mount_target.data]

  lifecycle {
    ignore_changes = [task_definition]
  }
}

