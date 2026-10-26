data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  oidc_host  = "token.actions.githubusercontent.com"
}

# Account-wide singleton: one GitHub OIDC provider shared by the four repositories.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# Read-only role for terraform plan in pull requests. Scoped to this repository's own pull_request
# and main-branch events via `sub`, with the org/repo-id segments wildcarded: GitHub appends
# immutable numeric IDs to `sub` for this org (repo:ORG@id/REPO@id:...), so a StringEquals on the
# old ID-less format silently never matches. The wildcards sit mid-string, not leading, so they
# still pass AWS's "Trust policy ... must evaluate ... not scoped to all" validation.
#
# `sub` is the ONLY condition here, by design, not by omission: this account's STS only honors `aud`
# and `sub` as AssumeRoleWithWebIdentity condition context for this OIDC provider. The GitHub-issued
# token also contains `repository` and `event_name`, but STS does not match them as condition keys.
# Requiring either makes the role permanently unassumable; this was confirmed empirically on
# 2026-10-26 (see var.repositories for the account-specific details).
# PR content is semi-trusted (it gets ReadOnlyAccess), so the attached policy below denies the
# data-plane reads it does not need.
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
  }
}

# Deploy role: only assumable from one of this repository's GitHub Environments (var.repositories),
# matched via `sub` (the proven-reliable claim — see plan_trust) rather than the `environment`
# condition key. Branch pinning comes from the environment's own deployment-branch policy
# (configured outside Terraform, restricted to `main`): GitHub never issues a token with this
# `environment` claim for a run on a different branch, so the job fails before a token exists.
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
      test     = "StringLike"
      variable = "${local.oidc_host}:sub"
      values = [
        for env in each.value.deploy_environments :
        "repo:${var.github_org}@*/${each.key}@*:environment:${env}"
      ]
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

  # ReadOnlyAccess/PowerUserAccess also grant s3:ListBucket. Explicitly deny listing any prefix
  # other than this repository's, including requests that omit the prefix entirely.
  statement {
    sid       = "DenyListingOutsideOwnPrefix"
    effect    = "Deny"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringNotLike"
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

  # AWS's own public parameters (arn:...:ssm:REGION::parameter/aws/service/*, no account ID — e.g.
  # the EKS-optimized AMI lookup the eks module reads at every plan) are never sensitive and are not
  # excluded here; only the project's own /auto-shop/* namespace and that public namespace are
  # allowed, everything else in this account is denied.
  statement {
    sid     = "DenySsmOutsideProjectContract"
    effect  = "Deny"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory"]
    not_resources = [
      "arn:${local.partition}:ssm:*:${local.account_id}:parameter/auto-shop/*",
      "arn:${local.partition}:ssm:*::parameter/aws/service/*",
    ]
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

# Deploy roles use PowerUserAccess plus the scoped IAM policy below. The boundary is required for
# roles they create; it is not attached to deploy roles because it denies access to the shared state
# bucket Terraform needs. Explicit denies in the IAM policy prevent CI roles from editing themselves.
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

# EKS checks whether its node-group service-linked role exists during CreateNodegroup. Only the
# k8s-infra deploy role manages node groups, so keep these read permissions out of the shared policy.
data "aws_iam_policy_document" "k8s_infra_nodegroup_role_read" {
  statement {
    sid       = "ReadEksNodegroupServiceLinkedRole"
    actions   = ["iam:GetRole", "iam:ListAttachedRolePolicies"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup"
    ]
  }
}

resource "aws_iam_role_policy" "k8s_infra_nodegroup_role_read" {
  name   = "eks-nodegroup-slr-read"
  role   = aws_iam_role.deploy["k8s-infra"].name
  policy = data.aws_iam_policy_document.k8s_infra_nodegroup_role_read.json
}
