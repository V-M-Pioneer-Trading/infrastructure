output "fleet_service_port" {
  description = "Port reserved for fleet-service on shared EC2 host."
  value       = var.fleet_service_port
}

output "fleet_service_ec2_ip" {
  description = "Shared EC2 public IP for fleet-service deployment."
  value       = data.terraform_remote_state.personal.outputs.ec2_instance_ip
}

output "fleet_service_base_url" {
  description = "Base URL apps and deploy scripts can use for fleet-service."
  value       = "http://${data.terraform_remote_state.personal.outputs.ec2_instance_ip}:${var.fleet_service_port}"
}
