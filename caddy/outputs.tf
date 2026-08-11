output "backend_domain" {
  description = "DNS name Caddy serves TLS for and CloudFront uses as its HTTPS backend origin."
  value       = var.backend_domain
}

output "caddy_bootstrap_document_name" {
  description = "SSM document that builds and runs the Caddy edge proxy."
  value       = aws_ssm_document.caddy_bootstrap.name
}
