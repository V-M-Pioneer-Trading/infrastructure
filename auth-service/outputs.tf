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

# THE FULL ENDPOINT URL, PATH INCLUDED — owner's decision, 2026-09-21.
# RFC 7662 calls this the introspection endpoint, and an endpoint URL is used
# verbatim: a client POSTs to exactly this string and never appends a path to
# it. `contract.endpoint.path` in meta/fixtures/introspection.json describes
# the route auth-service serves, not a suffix a caller adds. A base-URL form
# was considered and rejected: it would put the same `/auth/v1/introspect`
# literal in three client implementations to drift against.
output "auth_introspection_url" {
  description = "AUTH_INTROSPECTION_URL for the four --network host services (fleet, automation, navigation, agent), via the loopback-published port. This is the FULL endpoint URL including the /auth/v1/introspect path; clients use it verbatim and never append a path. st-gateway is on authnet and keeps using bridge DNS (http://auth-service:<port>/auth/v1/introspect), like its existing AUTH_SERVICE_URL."
  value       = "http://localhost:${var.auth_service_port}/auth/v1/introspect"
}

# meta#59 / auth-design.md decision 22 (2026-09-30). Full endpoint URL, path
# included, used verbatim - same rule as auth_introspection_url above. Same
# listener, same loopback publish, so the existing OUTPUT-chain rule already
# lets the --network host callers reach it; no firewall change.
output "auth_m2m_token_url" {
  description = "AUTH_M2M_TOKEN_URL for headless callers (automation-service now, ai-service later): the FULL /auth/v1/m2m-token endpoint URL via the loopback-published port. Clients use it verbatim."
  value       = "http://localhost:${var.auth_service_port}/auth/v1/m2m-token"
}

# Published for the same reason, and read the same way, as
# auth_introspection_secret_parameter_name: automation-service's bootstrap
# reads this parameter by name, and the shared EC2 role is already granted
# GetParameter on it by the policy in main.tf. Apply auth-service BEFORE
# automation-service: the consumer reads this output from remote state.
output "auth_m2m_caller_secret_automation_service_parameter_name" {
  description = "SSM parameter holding automation-service's caller secret, sent as X-Service-Secret to POST /auth/v1/m2m-token. Distinct from every other auth-service secret by construction; hand it to automation-service's stack only."
  value       = aws_ssm_parameter.auth_m2m_caller_secret_automation_service.name
}

output "auth_m2m_caller_secret_ai_service_parameter_name" {
  description = "SSM parameter holding ai-service's caller secret, sent as X-Service-Secret to POST /auth/v1/m2m-token. Hand it to ai-service's stack only (meta#59, not wired yet)."
  value       = aws_ssm_parameter.auth_m2m_caller_secret_ai_service.name
}
