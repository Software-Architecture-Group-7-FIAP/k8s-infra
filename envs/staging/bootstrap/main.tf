data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  oidc_host  = "token.actions.githubusercontent.com"

  # Per repository, from var.repositories.deploy_workflow_files. AWS rejects a leading wildcard here
  # ("Trust policy ... must evaluate ... which is not scoped to all"), so this has to be an exact
  # match, not a pattern — unlike `sub`, `job_workflow_ref` is not known to receive GitHub's
  # immutable-ID treatment (repository/repository_owner IDs already have their own dedicated claims,
  # so there is no reason for GitHub to also mangle this one); the separate `repository` condition
  # below is the one pinned to the ID-proof claim regardless.
  deploy_workflow_refs = {
    for repo, cfg in var.repositories : repo => [
      for file in cfg.deploy_workflow_files : "${var.github_org}/${repo}/.github/workflows/${file}@refs/heads/main"
    ]
  }
}

# Account-wide singleton: one GitHub OIDC provider shared by the four repositories.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# Read-only role for terraform plan in pull requests. Scoped to this repository's own pull_request
# and workflow_dispatch events (the two triggers ci.yml actually uses) via the stable `repository`
# and `event_name` claims. AWS separately requires every role trusting this OIDC provider to carry a
# condition on `sub` or `job_workflow_ref` specifically (rejects anything else as "not scoped to
# all"), so `sub` is also matched here — with the org/repo-id segments wildcarded, since GitHub
# appends immutable numeric IDs to `sub` for this org (repo:ORG@id/REPO@id:...) and a StringEquals on
# the old ID-less format silently never matches. The wildcards sit mid-string, not leading, so they
# still pass AWS's "not scoped to all" check; `repository`/`event_name` above are what actually do
# the narrow scoping and are unaffected by the ID suffixing. PR content is semi-trusted (it gets
# ReadOnlyAccess), so the attached policy below also denies the data-plane reads it does not need.
data "aws_iam_policy_document" "plan_trust" {
  for_each = var.repositories

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        "repo:${var.github_org}@*/${each.key}@*:pull_request",
        "repo:${var.github_org}@*/${each.key}@*:ref:refs/heads/main",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository"
      values   = ["${var.github_org}/${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:event_name"
      values   = ["pull_request", "workflow_dispatch"]
    }
  }
}

# Deploy role: only assumable from one of this repository's staging-type GitHub Environments AND
# from the exact apply/destroy workflow file at refs/heads/main (job_workflow_ref, matched by
# pattern — see deploy_workflow_refs). The environment condition alone is not enough: it is
# attached to the token regardless of which branch a workflow_dispatch ran from.
data "aws_iam_policy_document" "deploy_trust" {
  for_each = var.repositories

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository"
      values   = ["${var.github_org}/${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:environment"
      values   = each.value.deploy_environments
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:job_workflow_ref"
      values   = local.deploy_workflow_refs[each.key]
    }
  }
}

# State access is limited to the repository's own key prefix (state + native lock file).
data "aws_iam_policy_document" "state" {
  for_each = var.repositories

  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }

  statement {
    sid       = "ReadWriteOwnState"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}/${each.key}/*"]
  }

  # ReadOnlyAccess/PowerUserAccess grant S3 broadly (including GetObjectVersion on a versioned bucket);
  # deny every S3 action on every other repository's prefix, not just the three actions above.
  statement {
    sid     = "DenyOtherRepositoriesState"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      for repo in keys(var.repositories) : "arn:${local.partition}:s3:::${var.state_bucket}/${repo}/*" if repo != each.key
    ]
  }

  # Allow-list for the bucket itself: only the read actions needed to list/locate objects.
  # Everything else (ACLs, policy, versioning, lifecycle, encryption, replication, logging, notifications,
  # public access block, ownership controls, bucket deletion) is denied, including actions not yet
  # invented when this was written.
  statement {
    sid         = "DenyStateBucketAdministration"
    effect      = "Deny"
    not_actions = ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:GetEncryptionConfiguration"]
    resources   = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_policy" "state" {
  for_each = var.repositories

  name        = "auto-shop-tfstate-${each.key}"
  path        = var.iam_path
  description = "Terraform state access for ${each.key} only."
  policy      = data.aws_iam_policy_document.state[each.key].json
}

resource "aws_iam_role" "plan" {
  for_each = var.repositories

  name                 = "gh-plan-${each.key}"
  path                 = var.iam_path
  description          = "Read-only role for terraform plan in ${each.key} pull requests."
  assume_role_policy   = data.aws_iam_policy_document.plan_trust[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  for_each = var.repositories

  role       = aws_iam_role.plan[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "plan_state" {
  for_each = var.repositories

  role       = aws_iam_role.plan[each.key].name
  policy_arn = aws_iam_policy.state[each.key].arn
}

# PR content is semi-trusted: it runs terraform init/plan with this role's credentials. ReadOnlyAccess
# is still account-wide data-plane read, so explicitly deny the categories a plan never needs.
# Secrets Manager and DynamoDB are denied everywhere (no stack reads them at plan time); SSM is
# denied everywhere EXCEPT the project's own non-secret contract (.checkov.yaml CKV2_AWS_34), which
# the platform stack legitimately reads at plan time (cluster name, VPC ID/CIDR, RDS subnet CIDRs).
# lambda:GetFunction* and kms:Decrypt/GenerateDataKey* were dropped here: lambda-auth's own plan
# needs to read its function, and they added no real protection (the state bucket is SSE-S3, not
# KMS) while breaking a legitimate read.
data "aws_iam_policy_document" "plan_restrictions" {
  statement {
    sid       = "DenySecretsAndDynamoDb"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:Query", "dynamodb:BatchGetItem"]
    resources = ["*"]
  }

  statement {
    sid           = "DenySsmOutsideProjectContract"
    effect        = "Deny"
    actions       = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    not_resources = ["arn:${local.partition}:ssm:*:${local.account_id}:parameter/auto-shop/*"]
  }
}

resource "aws_iam_policy" "plan_restrictions" {
  name        = "auto-shop-plan-restrictions"
  path        = var.iam_path
  description = "Denies sensitive data-plane reads for PR-triggered plan roles (ReadOnlyAccess is otherwise account-wide)."
  policy      = data.aws_iam_policy_document.plan_restrictions.json
}

resource "aws_iam_role_policy_attachment" "plan_restrictions" {
  for_each = var.repositories

  role       = aws_iam_role.plan[each.key].name
  policy_arn = aws_iam_policy.plan_restrictions.arn
}

resource "aws_iam_role" "deploy" {
  for_each = var.repositories

  name                 = "gh-deploy-${each.key}"
  path                 = var.iam_path
  description          = "Deploy role for ${each.key}; assumable only from apply.yml/destroy.yml on main."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust[each.key].json
  max_session_duration = 7200
}

# Trade-off documented in README/ADR-0071: PowerUserAccess (no IAM/Organizations) plus a permissions
# boundary (below) that caps anything a deploy role creates, including roles it creates itself.
resource "aws_iam_role_policy_attachment" "deploy_poweruser" {
  for_each = var.repositories

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy_attachment" "deploy_state" {
  for_each = var.repositories

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.state[each.key].arn
}

# Permissions boundary every role created under /auto-shop/ must carry. It mirrors PowerUserAccess
# (no IAM, Organizations or account write) so a deploy role cannot create a new role, attach
# AdministratorAccess to it and assume it to escape its own boundary.
data "aws_iam_policy_document" "project_boundary" {
  statement {
    sid         = "PowerUserBoundary"
    not_actions = ["iam:*", "organizations:*", "account:*"]
    resources   = ["*"]
  }

  # Within the boundary, still allow the narrow IAM actions workloads legitimately need
  # (service-linked roles for ALB/EBS, and reading their own role).
  statement {
    sid       = "AllowServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }

  statement {
    sid       = "AllowReadOwnRole"
    actions   = ["iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}*"]
  }

  # The boundary caps IAM escalation but, being PowerUser-shaped, otherwise leaves the data plane
  # open. Without these two denies a role bounded by this policy could still create a role trusting
  # itself, grant it inline s3:* (capped at this same boundary, which permits S3), sts:AssumeRole
  # into it, and read every other repository's Terraform state (RDS credentials, JWT material) —
  # the per-repo Deny in aws_iam_policy_document.state lives in an *identity* policy attached only
  # to the gh-* roles, not here. No workload in this project legitimately chains roles, so deny it
  # outright; the durable control is a bucket policy on the state bucket itself (owned by whichever
  # repo manages it), this is defense in depth from the boundary side.
  statement {
    sid       = "DenyRoleChaining"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}*"]
  }

  statement {
    sid     = "DenyStateBucketRegardlessOfIdentityPolicy"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}",
      "arn:${local.partition}:s3:::${var.state_bucket}/*",
    ]
  }
}

resource "aws_iam_policy" "project_boundary" {
  name        = "auto-shop-boundary"
  path        = var.iam_path
  description = "Permissions boundary for every IAM role created under ${var.iam_path}."
  policy      = data.aws_iam_policy_document.project_boundary.json
}

data "aws_iam_policy_document" "deploy_iam" {
  # CreateRole is the escalation vector: the iam:PermissionsBoundary condition key only exists in the
  # request context for CreateRole/PutRolePermissionsBoundary, so it must stand alone. Every role
  # created under the project path is forced to carry the boundary from birth; IAM caps its effective
  # permissions at that boundary regardless of which policies are attached to it afterwards.
  statement {
    sid       = "CreateRoleWithBoundary"
    actions   = ["iam:CreateRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.project_boundary.arn]
    }
  }

  # Everything else on an already-bounded role: the boundary cannot be changed here (that needs
  # iam:PutRolePermissionsBoundary, never granted) or removed (explicit Deny below).
  statement {
    sid = "ManageOwnManagedRoles"
    actions = [
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
      "iam:DeleteRole", "iam:GetRole", "iam:ListRoleTags", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole", "iam:DetachRolePolicy",
      "iam:DeleteRolePolicy", "iam:PutRolePolicy",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}*"]
  }

  statement {
    sid     = "AttachOnlyApprovedPolicies"
    actions = ["iam:AttachRolePolicy"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}*",
    ]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}*",
        "arn:${local.partition}:iam::aws:policy/AmazonEKS*",
        "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
        "arn:${local.partition}:iam::aws:policy/AmazonEBSCSIDriverPolicy",
        "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy",
      ]
    }
  }

  statement {
    sid = "ManageProjectPoliciesAndInstanceProfiles"
    actions = [
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}*",
      "arn:${local.partition}:iam::${local.account_id}:instance-profile${var.iam_path}*",
    ]
  }

  # PassRole limited to the project's own roles, and only when AWS is about to use that role as the
  # named service (never to a human, never to a role outside /auto-shop/).
  statement {
    sid       = "PassProjectRolesToAwsServices"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values = [
        "eks.amazonaws.com", "eks-fargate-pods.amazonaws.com", "pods.eks.amazonaws.com",
        "ec2.amazonaws.com", "lambda.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "PassAwsServiceRoles"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }

  statement {
    sid = "ManageEksOidcProviders"
    actions = [
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:oidc-provider/oidc.eks.*"]
  }

  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*"]
  }

  # Belt and suspenders: even if a statement above were misconfigured, CI roles can never touch
  # themselves, the boundary policy, the deploy-iam policy itself, the state policies, or the OIDC
  # provider (read-only access to all of them is preserved).
  statement {
    sid    = "DenyEditingCiIdentities"
    effect = "Deny"
    not_actions = [
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:ListInstanceProfilesForRole",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-*",
      "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-deploy-iam",
      "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-boundary",
      "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-tfstate-*",
      "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-plan-restrictions",
      aws_iam_openid_connect_provider.github.arn,
    ]
  }

  statement {
    sid       = "DenyRemovingOwnBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deploy_iam" {
  name        = "auto-shop-deploy-iam"
  path        = var.iam_path
  description = "IAM management restricted to the project path, gated by a permissions boundary."
  policy      = data.aws_iam_policy_document.deploy_iam.json
}

resource "aws_iam_role_policy_attachment" "deploy_iam" {
  for_each = var.repositories

  role       = aws_iam_role.deploy[each.key].name
  policy_arn = aws_iam_policy.deploy_iam.arn
}
