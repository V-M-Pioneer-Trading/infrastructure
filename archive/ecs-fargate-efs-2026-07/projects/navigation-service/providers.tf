terraform {
  backend "s3" {
    key          = "projects/navigation-service/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  required_version = ">= 1.10.0"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      Project     = "navigation-service"
      Terraform   = "true"
    }
  }
}

