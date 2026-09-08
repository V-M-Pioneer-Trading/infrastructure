output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.main.arn
}

output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.service.name
}

output "task_security_group_id" {
  description = "Task security group ID."
  value       = aws_security_group.task.id
}

output "efs_file_system_id" {
  description = "EFS file system ID."
  value       = aws_efs_file_system.data.id
}

output "efs_access_point_id" {
  description = "EFS access point ID."
  value       = aws_efs_access_point.data.id
}

output "log_group_name" {
  description = "CloudWatch log group name."
  value       = aws_cloudwatch_log_group.service.name
}

output "task_role_arn" {
  description = "IAM task role ARN."
  value       = aws_iam_role.task.arn
}

