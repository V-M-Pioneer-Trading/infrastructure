terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "radomskyi-tfstate"
    key          = "caddy/terraform.tfstate"
    region       = "eu-central-1"
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.58"
    }
  }
}
