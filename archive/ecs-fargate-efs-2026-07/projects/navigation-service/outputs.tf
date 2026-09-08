output "cluster_name" {
  description = "ECS cluster name."
  value       = module.navigation_service.cluster_name
}

output "service_name" {
  description = "ECS service name."
  value       = module.navigation_service.service_name
}

output "efs_file_system_id" {
  description = "EFS file system ID."
  value       = module.navigation_service.efs_file_system_id
}

output "task_security_group_id" {
  description = "Task security group ID."
  value       = module.navigation_service.task_security_group_id
}

output "log_group_name" {
  description = "CloudWatch log group name."
  value       = module.navigation_service.log_group_name
}

output "sqlite_db_path" {
  description = "SQLite database path passed to container."
  value       = var.sqlite_db_path
}

