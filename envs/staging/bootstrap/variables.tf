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
    role, matched via the `sub` claim as `repo:ORG@*/REPO@*:environment:<name>`.

    Branch pinning for deploy is NOT done with an IAM condition (`job_workflow_ref`): empirical validation
    in this AWS account found that AssumeRoleWithWebIdentity only honors `aud` and `sub` as trust
    policy condition keys for this provider. The GitHub-issued token also contains `repository`,
    `event_name`, `environment` and `job_workflow_ref`, but STS does not match those claims as
    condition context; requiring them made the role unassumable (confirmed during PR #12 on 2026-10-26).
    The branch restriction instead comes from each repository's GitHub Environment deployment-branch
    policy (configured outside Terraform, via the GitHub API/UI, restricted to `main`): GitHub refuses
    to start the job when the branch does not match. The k8s-infra CI checks its `staging` policy daily.

    lambda-auth and auto-shop-system are a later phase; the environments below are a placeholder for
    when those repositories configure matching GitHub Environments, not a current operational grant.
  EOT
  type = map(object({
    deploy_environments = list(string)
  }))
  default = {
    "k8s-infra" = {
      deploy_environments = ["staging"]
    }
    "database-infra" = {
      deploy_environments = ["staging"]
    }
    "lambda-auth" = {
      deploy_environments = ["hml", "prd"]
    }
    "auto-shop-system" = {
      deploy_environments = ["hml", "prd"]
    }
  }
}

variable "iam_path" {
  description = "IAM path that deploy roles are allowed to manage. Every project role and policy must live under it."
  type        = string
  default     = "/auto-shop/"
}
