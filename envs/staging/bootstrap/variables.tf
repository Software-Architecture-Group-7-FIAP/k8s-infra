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

    Branch pinning for deploy is NOT done with an IAM condition (job_workflow_ref): empirically,
    on this AWS account, AssumeRoleWithWebIdentity only honors the `aud` and `sub` claims as trust
    policy condition keys — `repository`, `event_name`, `environment` and `job_workflow_ref` are
    present in the decoded ID token (confirmed via the "Dump OIDC claims" CI step) but are not
    matched as condition context by STS here, and requiring any of them as a condition makes the
    role permanently unassumable (confirmed the hard way on 2026-10-26: PR #12's plan job failed
    AssumeRoleWithWebIdentity even though every non-sub claim printed matched the condition exactly;
    removing them was what fixed it). The branch restriction instead comes from each repository's
    GitHub Environment deployment-branch policy (configured outside Terraform, via the GitHub API/UI,
    restricted to `main`): GitHub refuses to even start the job — so no token with that `environment`
    claim is ever issued — when the running branch doesn't match the policy.

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
