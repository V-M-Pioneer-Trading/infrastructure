output "navigation_service_port" {
  description = "Port reserved for navigation-service on shared EC2 host."
  value       = var.navigation_service_port
}

output "navigation_service_security_group_id" {
  description = "Shared EC2 security group updated for navigation-service traffic."
  value       = data.terraform_remote_state.personal.outputs.ec2_security_group_id
}

output "navigation_service_ec2_ip" {
  description = "Shared EC2 public IP for navigation-service deployment."
  value       = data.terraform_remote_state.personal.outputs.ec2_instance_ip
}

output "navigation_service_base_url" {
  description = "Base URL apps and deploy scripts can use for navigation-service."
  value       = "http://${data.terraform_remote_state.personal.outputs.ec2_instance_ip}:${var.navigation_service_port}"
}
