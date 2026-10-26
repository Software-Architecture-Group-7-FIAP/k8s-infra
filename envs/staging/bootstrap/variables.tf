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
  description = <<-EOT
    Repositories allowed to assume a plan role (PR terraform plan) and a deploy role (apply/destroy).
    deploy_environments lists the GitHub Environments whose deploy workflow may assume the deploy
    role; deploy_workflow_files lists the workflow file basenames (in .github/workflows/) allowed to
    do so, each matched at refs/heads/main only. k8s-infra and database-infra deploy a single
    efemeral staging environment from apply.yml/destroy.yml; lambda-auth and auto-shop-system are a
    later phase and have not fixed their own workflow names yet — the defaults below are a
    placeholder to be corrected before those repositories' CI/CD is implemented, not a current
    operational grant (no workflow in either repository names itself this way yet).
    Trust conditions use the stable repository/environment/job_workflow_ref claims, never the `sub`
    claim: GitHub appends immutable numeric IDs to `sub` for this org (repo:ORG@id/REPO@id:...),
    which breaks plain string matching; the dedicated claims are unaffected.
  EOT
  type = map(object({
    deploy_environments   = list(string)
    deploy_workflow_files = list(string)
  }))
  default = {
    "k8s-infra" = {
      deploy_environments   = ["staging"]
      deploy_workflow_files = ["apply.yml", "destroy.yml"]
    }
    "database-infra" = {
      deploy_environments   = ["staging"]
      deploy_workflow_files = ["apply.yml", "destroy.yml"]
    }
    "lambda-auth" = {
      deploy_environments   = ["hml", "prd"]
      deploy_workflow_files = ["apply.yml", "destroy.yml"]
    }
    "auto-shop-system" = {
      deploy_environments   = ["hml", "prd"]
      deploy_workflow_files = ["apply.yml", "destroy.yml"]
    }
  }
}

variable "iam_path" {
  description = "IAM path that deploy roles are allowed to manage. Every project role and policy must live under it."
  type        = string
  default     = "/auto-shop/"
}
