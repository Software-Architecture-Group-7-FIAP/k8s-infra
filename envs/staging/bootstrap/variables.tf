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

variable "plan_environments" {
  description = "GitHub Environments that read-only plan jobs use in addition to the exact main-ref subject."
  type        = map(list(string))
  default = {
    "k8s-infra" = ["staging"]
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
    Repositories allowed to assume a plan role from main-branch/Environment workflows and a deploy role.
    deploy_environments lists the GitHub Environments whose deploy workflow may assume the
    repository's deploy role. deploy_workflows contains exact Environment/workflow/ref tuples; each
    tuple creates a separate trust statement. workflow_ref optionally adds an exact GitHub custom
    subject suffix (`owner/repo/.github/workflows/file.yml@refs/...`) during subject-template
    migration. Trust policies use only aud/sub StringEquals conditions. k8s-infra pins immutable
    owner/repository IDs in both its default and custom subjects; auto-shop-system retains its
    existing exact legacy name-based default subject during migration.

    The IAM `sub` for a job using a GitHub Environment names the repository and environment, but does
    not encode the branch. Each repository must therefore configure exact Environment deployment
    branch policies and validate the expected branch in its workflow before requesting credentials.
    `plan_environments` adds Environment subjects to the default exact main-ref subject. Only the
    k8s-infra plan job requests OIDC under a GitHub Environment (`staging`); database-infra's
    read-only plan job has no Environment and uses its `refs/heads/main` subject. Add an Environment
    here only when the corresponding plan job requests OIDC under that Environment.

    For k8s-infra and database-infra, the existing `staging` Environment remains main-only for
    lifecycle workflows. k8s-infra HML uses its separately scoped gh-deploy-k8s-hml role from the
    saved-plan Apply/Destroy workflows; branch-pipeline has no AWS trust. k8s-infra PRD is disabled.
    Database infrastructure retains its separate HML and PRD delivery environments.

    auto-shop-system deploys from `hml` on develop and `prd` on main; its `operations` Environment
    is used by the app's separate read-only preflight role, not this deploy-role map. lambda-auth
    deploys to `hml` or `prd` through workflow_dispatch from main. Their exact Environment branch
    policies are GitHub settings outside Terraform and must stay aligned with those workflow guards.
  EOT
  type = map(object({
    deploy_environments = list(string)
    deploy_workflows = list(object({
      environment  = string
      workflow     = string
      ref          = string
      workflow_ref = optional(string, "")
    }))
  }))
  default = {
    "k8s-infra" = {
      deploy_environments = ["staging"]
      deploy_workflows = [
        { environment = "staging", workflow = "Apply", ref = "refs/heads/main", workflow_ref = "Software-Architecture-Group-7-FIAP/k8s-infra/.github/workflows/apply.yml@refs/heads/main" },
        { environment = "staging", workflow = "Destroy", ref = "refs/heads/main", workflow_ref = "Software-Architecture-Group-7-FIAP/k8s-infra/.github/workflows/destroy.yml@refs/heads/main" },
      ]
    }
    "database-infra" = {
      deploy_environments = ["staging", "hml", "production"]
      deploy_workflows = [
        { environment = "staging", workflow = "Apply database staging", ref = "refs/heads/main" },
        { environment = "staging", workflow = "Destroy database staging", ref = "refs/heads/main" },
        { environment = "hml", workflow = "Database infrastructure delivery", ref = "refs/heads/develop" },
        { environment = "production", workflow = "Database infrastructure delivery", ref = "refs/heads/main" },
      ]
    }
    "lambda-auth" = {
      deploy_environments = ["hml", "prd"]
      deploy_workflows = [
        { environment = "hml", workflow = "Promote lambda-auth", ref = "refs/heads/main" },
        { environment = "prd", workflow = "Promote lambda-auth", ref = "refs/heads/main" },
      ]
    }
    "auto-shop-system" = {
      deploy_environments = ["hml", "prd"]
      deploy_workflows = [
        { environment = "hml", workflow = "CD Staging", ref = "refs/heads/develop" },
        { environment = "prd", workflow = "CD Production", ref = "refs/heads/main" },
        { environment = "prd", workflow = "Lifecycle ledger bootstrap", ref = "refs/heads/main" },
      ]
    }
  }
}

variable "iam_path" {
  description = "IAM path that deploy roles are allowed to manage. Every project role and policy must live under it."
  type        = string
  default     = "/auto-shop/"
}
