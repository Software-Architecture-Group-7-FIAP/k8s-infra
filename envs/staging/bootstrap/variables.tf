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

variable "github_org_id" {
  description = "Immutable numeric GitHub organization ID embedded in OIDC subject claims."
  type        = string
  default     = "279547328"
}

variable "github_repository_ids" {
  description = "Immutable GitHub repository IDs embedded in OIDC subject claims; update if a repository is recreated."
  type        = map(string)
  default = {
    "k8s-infra"        = "1431503198"
    "database-infra"   = "1420971567"
    "lambda-auth"      = "1418895421"
    "auto-shop-system" = "1221936756"
  }
}

variable "state_bucket" {
  description = "Terraform state bucket shared by every repository (one key prefix per repository)."
  type        = string
  default     = "auto-shop-tfstate-035611741563-use1"
}

variable "plan_environments" {
  description = "GitHub Environments that replace the bare main-ref subject for read-only plan roles."
  type        = map(list(string))
  default = {
    "k8s-infra"      = ["staging"]
    "database-infra" = ["aws-plan"]
  }
}

variable "plan_state_keys" {
  description = "Exact S3 state object keys that each plan role may read. Update this map when a Terraform root is added."
  type        = map(list(string))
  default = {
    "k8s-infra" = [
      "k8s-infra/staging/foundation.tfstate",
      "k8s-infra/staging/platform.tfstate",
      "k8s-infra/hml/terraform.tfstate",
      "k8s-infra/production/terraform.tfstate",
    ]
    "database-infra"   = ["database-infra/staging/terraform.tfstate"]
    "lambda-auth"      = ["lambda-auth/_no_remote_state_configured.tfstate"]
    "auto-shop-system" = ["auto-shop-system/infra/aws/staging/terraform.tfstate"]
  }
}

variable "plan_artifact_prefixes" {
  description = "S3 object prefixes where each plan role may create private saved plans; empty entries deny plan uploads."
  type        = map(list(string))
  default = {
    "k8s-infra"        = ["k8s-infra/staging/plans/*"]
    "database-infra"   = []
    "lambda-auth"      = []
    "auto-shop-system" = []
  }
}

variable "repositories" {
  description = <<-EOT
    Repositories allowed to assume a plan role from protected main-branch/Environment workflows and a
    deploy role. The `sub` claim uses the exact default immutable organization and repository IDs,
    so a repository rename or recreation cannot reuse the old trust. `deploy_environments` lists the
    GitHub Environments whose immutable default subjects may assume the generic deploy role.

    Under the default immutable GitHub subject, a job using an Environment has a subject containing
    the repository IDs and Environment name, but not the workflow file or branch. AWS STS accepts
    `aud` and `sub` for this provider; workflow/ref claims cannot be separate IAM trust conditions.
    Therefore each Environment must have an exact deployment-branch policy, and its workflow must
    validate the expected event/ref before requesting credentials.

    When `plan_environments` is set for a repository, its plan role accepts only those Environment
    subjects rather than a bare main-ref subject. k8s-infra's
    lifecycle jobs use `staging`; database-infra's read-only plan uses `aws-plan`, while its actual
    apply/destroy jobs use `staging` on main. The validation-only database delivery workflow does not
    receive deploy trust. The dedicated lambda-auth HML role is separate from the generic deploy role
    and currently has only HML state access pending a reviewed Terraform plan and generated policy.

    auto-shop-system deploys from `hml` on develop and `prd` on main. lambda-auth's generic deploy
    role is restricted to `prd`; HML uses its dedicated role. Environment branch policies are GitHub
    settings outside Terraform and must stay aligned with workflow guards.
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
      deploy_environments = ["prd"]
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
