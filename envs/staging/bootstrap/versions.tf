terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  backend "s3" {
    bucket       = "auto-shop-tfstate-035611741563-use1"
    key          = "k8s-infra/staging/bootstrap.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "auto-shop"
      Environment = "staging"
      ManagedBy   = "Terraform"
      Repository  = "k8s-infra"
      Stack       = "bootstrap"
    }
  }
}
