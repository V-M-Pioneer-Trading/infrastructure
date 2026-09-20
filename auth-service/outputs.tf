output "auth_service_port" {
  description = "Port reserved for auth-service on shared EC2 host — consumed by caddy/main.tf in increment 3 Stage 4."
  value       = var.auth_service_port
}

output "auth_service_data_volume_id" {
  description = "Encrypted EBS volume ID mounted for auth-service's SQLite file."
  value       = aws_ebs_volume.auth_service_data.id
}

output "auth_service_shared_secret_parameter_name" {
  description = "SSM parameter holding the shared secret st-gateway presents to auth-service's GET /auth/v1/token — consumed by agent-service/main.tf, which owns st-gateway's container (increment 3 Stage 5). THE VAULT KEY: st-gateway is the only other container that may ever receive it."
  value       = aws_ssm_parameter.auth_service_shared_secret.name
}

# Published now, injected later. meta#80 steps 4-9 add one `aws ssm
# get-parameter` line and one `-e AUTH_INTROSPECTION_SECRET` to each consumer
# stack's bootstrap as its client lands; nothing is injected into a consumer
# container by this step, because a service that does not call the center yet
# gains nothing from holding the secret. The shared EC2 role is already
# granted GetParameter on this ARN by the policy in main.tf — the same
# arrangement that already lets agent-service's bootstrap read the vault
# secret — so those steps need no extra IAM either.
output "auth_introspection_secret_parameter_name" {
  description = "SSM parameter holding the introspection secret every calling service presents in X-Introspection-Secret. Distinct from the vault secret by construction; safe to hand to every stack."
  value       = aws_ssm_parameter.auth_introspection_secret.name
}

output "auth_introspection_url" {
  description = "AUTH_INTROSPECTION_URL for the four --network host services (fleet, automation, navigation, agent), via the loopback-published port. st-gateway is on authnet and keeps using bridge DNS (http://auth-service:<port>/auth/v1/introspect), like its existing AUTH_SERVICE_URL."
  value       = "http://localhost:${var.auth_service_port}/auth/v1/introspect"
}
