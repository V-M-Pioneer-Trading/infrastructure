output "agent_service_port" {
  description = "Port reserved for agent-service on shared EC2 host."
  value       = var.agent_service_port
}

output "agent_service_ec2_ip" {
  description = "Shared EC2 public IP for agent-service deployment."
  value       = data.terraform_remote_state.personal.outputs.ec2_instance_ip
}

output "agent_service_base_url" {
  description = "Base URL apps and deploy scripts can use for agent-service."
  value       = "http://${data.terraform_remote_state.personal.outputs.ec2_instance_ip}:${var.agent_service_port}"
}

output "agent_service_mysql_data_volume_id" {
  description = "Encrypted EBS volume ID mounted for agent-service's MySQL data."
  value       = aws_ebs_volume.agent_service_mysql_data.id
}
