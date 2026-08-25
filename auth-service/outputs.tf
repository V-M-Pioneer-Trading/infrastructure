output "auth_service_port" {
  description = "Port reserved for auth-service on shared EC2 host — consumed by caddy/main.tf in increment 3 Stage 4."
  value       = var.auth_service_port
}

output "auth_service_data_volume_id" {
  description = "Encrypted EBS volume ID mounted for auth-service's SQLite file."
  value       = aws_ebs_volume.auth_service_data.id
}

output "auth_service_shared_secret_parameter_name" {
  description = "SSM parameter holding the shared secret st-gateway presents to auth-service's GET /auth/v1/token — consumed by agent-service/main.tf, which owns st-gateway's container (increment 3 Stage 5)."
  value       = aws_ssm_parameter.auth_service_shared_secret.name
}
