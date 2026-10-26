variable "aws_region" {
  description = "AWS region for every Fase 3 resource."
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = "Guard against applying to the wrong AWS account."
  type        = string
  default     = "035611741563"
}

variable "github_org" {
  description = "GitHub organization that owns the four repositories."
  type        = string
  default     = "Software-Architecture-Group-7-FIAP"
}

variable "state_bucket" {
  description = "Terraform state bucket shared by every repository (one key prefix per repository)."
  type        = string
  default     = "auto-shop-tfstate-035611741563-use1"
}

variable "repositories" {
  description = "Repositories allowed to assume a plan role and a deploy role, with the git refs/environments allowed to deploy."
  type = map(object({
    deploy_subjects = list(string)
  }))
  default = {
    "k8s-infra" = {
      deploy_subjects = ["ref:refs/heads/main", "environment:staging"]
    }
    "database-infra" = {
      deploy_subjects = ["ref:refs/heads/main", "environment:staging"]
    }
    "lambda-auth" = {
      deploy_subjects = ["ref:refs/heads/main", "ref:refs/heads/develop", "environment:hml", "environment:prd"]
    }
    "auto-shop-system" = {
      deploy_subjects = ["ref:refs/heads/main", "ref:refs/heads/develop", "environment:hml", "environment:prd"]
    }
  }
}

variable "iam_path" {
  description = "IAM path that deploy roles are allowed to manage. Every project role and policy must live under it."
  type        = string
  default     = "/auto-shop/"
}
