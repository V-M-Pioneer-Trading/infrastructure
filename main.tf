provider "aws" {
  region = var.aws_region
}

data "terraform_remote_state" "personal" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "personal/terraform.tfstate"
    region = var.aws_region
  }
}

resource "aws_vpc_security_group_ingress_rule" "navigation_service_from_shared_sg" {
  description                  = "Allow navigation-service traffic on shared EC2 security group."
  security_group_id            = data.terraform_remote_state.personal.outputs.ec2_security_group_id
  referenced_security_group_id = data.terraform_remote_state.personal.outputs.ec2_security_group_id
  from_port                    = var.navigation_service_port
  to_port                      = var.navigation_service_port
  ip_protocol                  = "tcp"
}
