output "auth_service_port" {
  description = "Port reserved for auth-service on shared EC2 host — consumed by caddy/main.tf in increment 3 Stage 4."
  value       = var.auth_service_port
}

output "auth_service_data_volume_id" {
  description = "Encrypted EBS volume ID mounted for auth-service's SQLite file."
  value       = aws_ebs_volume.auth_service_data.id
}
