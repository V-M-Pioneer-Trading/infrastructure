output "automation_service_port" {
  description = "Port reserved for automation-service on shared EC2 host."
  value       = var.automation_service_port
}

output "automation_service_ec2_ip" {
  description = "Shared EC2 public IP for automation-service deployment."
  value       = data.terraform_remote_state.personal.outputs.ec2_instance_ip
}

output "automation_service_base_url" {
  description = "Base URL apps and deploy scripts can use for automation-service."
  value       = "http://${data.terraform_remote_state.personal.outputs.ec2_instance_ip}:${var.automation_service_port}"
}

output "automation_service_postgres_data_volume_id" {
  description = "Encrypted EBS volume ID mounted for automation-service's Postgres data."
  value       = aws_ebs_volume.automation_service_postgres_data.id
}
