data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  oidc_host  = "token.actions.githubusercontent.com"
  repo_subject = {
    for repo in keys(var.repositories) :
    repo => "repo:${var.github_org}@${var.github_org_id}/${repo}@${var.github_repository_ids[repo]}"
  }
}

# Account-wide singleton: one GitHub OIDC provider shared by the four repositories.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# Read-only role for coordinator-authorized terraform plans from main-branch jobs and explicitly listed
# protected GitHub Environments. The `sub` condition matches the default immutable organization and
# repository IDs exactly, so a repository rename or recreation cannot reuse the old repository's trust.
#
# `sub` is the ONLY condition here, by design, not by omission: this account's STS only honors `aud`
# and `sub` as AssumeRoleWithWebIdentity condition context for this OIDC provider. The GitHub-issued
# token also contains workflow/ref claims, but STS does not match them as condition keys; this was
# confirmed empirically on 2026-10-26. With GitHub's default immutable subject, workflow and branch
# restrictions are enforced by the protected Environment's deployment-branch policy and by each
# workflow's pre-credential ref/event checks. Pull requests are excluded from AWS credentials.
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
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values = concat(
        length(lookup(var.plan_environments, each.key, [])) == 0 ? [
          "${local.repo_subject[each.key]}:ref:refs/heads/main"
        ] : [],
        [
          for env in lookup(var.plan_environments, each.key, []) :
          "${local.repo_subject[each.key]}:environment:${env}"
        ]
      )
    }
  }
}

# Deploy role: trust only the configured default immutable Environment subjects. GitHub does not
# include workflow/ref in its default immutable Environment subject, and STS cannot match those
# claims separately. Each Environment must therefore have the exact deployment-branch policy, and
# its workflow must check the expected event/ref before requesting credentials.
data "aws_iam_policy_document" "deploy_trust" {
  for_each = var.repositories

  dynamic "statement" {
    for_each = each.value.deploy_environments

    content {
      actions = ["sts:AssumeRoleWithWebIdentity"]
      effect  = "Allow"

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
        variable = "${local.oidc_host}:sub"
        values   = ["${local.repo_subject[each.key]}:environment:${statement.value}"]
      }
    }
  }
}

# Read-only identity for the coordinator-triggered staging orphan audit. The staging Environment
# policy and workflow guard restrict credential requests to main and orphan-audit.yml.
data "aws_iam_policy_document" "orphan_audit_trust" {
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
      variable = "${local.oidc_host}:sub"
      values   = ["${local.repo_subject["k8s-infra"]}:environment:staging"]
    }
  }
}

data "aws_iam_policy_document" "orphan_audit" {
  statement {
    sid = "ListAndDescribeSessionResources"
    actions = [
      "ec2:DescribeAddresses",
      "ec2:DescribeInstances",
      "ec2:DescribeNatGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVolumes",
      "eks:ListClusters",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroups",
      "logs:DescribeLogGroups",
      "rds:DescribeDBClusterSnapshots",
      "rds:DescribeDBClusters",
      "rds:DescribeDBInstances",
      "rds:DescribeDBProxies",
      "rds:DescribeDBSnapshots",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ListOnlyLifecycleStateKeys"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values = [
        "k8s-infra/staging/foundation.tfstate",
        "k8s-infra/staging/platform.tfstate",
        "k8s-infra/hml/terraform.tfstate",
        "k8s-infra/production/terraform.tfstate",
      ]
    }
  }

  statement {
    sid     = "ReadOnlyLifecycleStateObjects"
    actions = ["s3:GetObject"]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/foundation.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/platform.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/hml/terraform.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/production/terraform.tfstate",
    ]
  }
}

resource "aws_iam_role" "orphan_audit" {
  name                 = "gh-audit-k8s-infra"
  path                 = var.iam_path
  description          = "Read-only AWS and Terraform state inventory for k8s-infra staging teardown."
  assume_role_policy   = data.aws_iam_policy_document.orphan_audit_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "orphan_audit" {
  name   = "orphan-audit-k8s-infra-read-only"
  role   = aws_iam_role.orphan_audit.name
  policy = data.aws_iam_policy_document.orphan_audit.json
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
      values = each.key == "k8s-infra" ? [
        "k8s-infra/staging/*",
        ] : each.key == "lambda-auth" ? [
        "lambda-auth/prd/*",
      ] : ["${each.key}/*"]
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
      values = each.key == "k8s-infra" ? [
        "k8s-infra/staging/*",
      ] : ["${each.key}/*"]
    }
  }

  statement {
    sid     = "ReadWriteOwnState"
    actions = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = each.key == "k8s-infra" ? [
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/foundation.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/foundation.tfstate.tflock",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/platform.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/platform.tfstate.tflock",
      ] : each.key == "lambda-auth" ? [
      "arn:${local.partition}:s3:::${var.state_bucket}/lambda-auth/prd/terraform.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/lambda-auth/prd/terraform.tfstate.tflock",
    ] : ["arn:${local.partition}:s3:::${var.state_bucket}/${each.key}/*"]
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

  # The generic k8s-infra deploy identity has PowerUserAccess for shared staging operations.
  # Explicitly keep it away from isolated environment states and HML/PRD plan files so those roots
  # can only be applied through their separately reviewed role and state path.
  statement {
    sid     = "DenyIsolatedK8sEnvironmentStateAndPlans"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/hml/*",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/production/*",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/apply/hml.tfplan",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/destroy/hml.tfplan",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/apply/manifest-hml.json",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/destroy/manifest-hml.json",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/apply/production.tfplan",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/destroy/production.tfplan",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/apply/manifest-production.json",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/destroy/manifest-production.json",
    ]
  }

  # Bucket metadata is read-only: CI can inspect location, versioning, encryption, public-access
  # block, and ownership controls. Every bucket mutation (ACLs, policy, lifecycle, replication,
  # logging, notifications, public-access block, ownership controls, deletion) remains denied.
  statement {
    sid    = "DenyStateBucketAdministration"
    effect = "Deny"
    not_actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
    ]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }

  statement {
    sid = "ReadStateBucketPrivacyControls"
    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
    ]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
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
  description          = "Read-only role for terraform plans in ${each.key} authorized workflows."
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
  policy_arn = aws_iam_policy.plan_state[each.key].arn

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "plan_artifacts" {
  for_each = aws_iam_policy.plan_artifacts

  role       = aws_iam_role.plan[each.key].name
  policy_arn = each.value.arn
}

data "aws_iam_policy_document" "plan_state" {
  for_each = var.repositories

  statement {
    sid       = "ListOnlyExactStateKeys"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = lookup(var.plan_state_keys, each.key, [])
    }
  }

  statement {
    sid       = "DenyListingOutsideExactStateKeys"
    effect    = "Deny"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:prefix"
      values   = lookup(var.plan_state_keys, each.key, [])
    }
  }

  statement {
    sid     = "DenyListingOtherBuckets"
    effect  = "Deny"
    actions = ["s3:ListBucket", "s3:ListBucketVersions"]
    not_resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}",
    ]
  }

  statement {
    sid     = "DenyObjectReadsOutsideExactStateKeys"
    effect  = "Deny"
    actions = ["s3:GetObject*"]
    not_resources = [
      for key in lookup(var.plan_state_keys, each.key, []) :
      "arn:${local.partition}:s3:::${var.state_bucket}/${key}"
    ]
  }

  statement {
    sid       = "DenyBucketEnumeration"
    effect    = "Deny"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid    = "DenyS3WritesOutsidePlanArtifacts"
    effect = "Deny"
    actions = [
      "s3:PutObject*", "s3:DeleteObject*", "s3:CreateMultipartUpload",
      "s3:UploadPart", "s3:CompleteMultipartUpload", "s3:AbortMultipartUpload",
    ]
    not_resources = length(lookup(var.plan_artifact_prefixes, each.key, [])) > 0 ? [
      for prefix in lookup(var.plan_artifact_prefixes, each.key, []) :
      "arn:${local.partition}:s3:::${var.state_bucket}/${prefix}"
      ] : [
      "arn:${local.partition}:s3:::${var.state_bucket}/_no_plan_uploads_configured/*",
    ]
  }

  statement {
    sid       = "DenyPlanArtifactDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObject*"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}/*"]
  }

  statement {
    sid    = "DenyStateBucketAdministration"
    effect = "Deny"
    not_actions = [
      "s3:ListBucket", "s3:GetBucketLocation", "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration", "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
    ]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }
}

resource "aws_iam_policy" "plan_state" {
  for_each = var.repositories

  name        = "auto-shop-plan-state-${each.key}"
  path        = var.iam_path
  description = "Read-only exact Terraform state access for plan role ${each.key}; state writes are denied."
  policy      = data.aws_iam_policy_document.plan_state[each.key].json
}

data "aws_iam_policy_document" "plan_artifacts" {
  for_each = {
    for repo, prefixes in var.plan_artifact_prefixes : repo => prefixes
    if length(prefixes) > 0
  }

  statement {
    sid     = "CreatePrivateSavedPlans"
    actions = ["s3:PutObject"]
    resources = [
      for prefix in each.value : "arn:${local.partition}:s3:::${var.state_bucket}/${prefix}"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }
}

resource "aws_iam_policy" "plan_artifacts" {
  for_each = data.aws_iam_policy_document.plan_artifacts

  name        = "auto-shop-plan-artifacts-${each.key}"
  path        = var.iam_path
  description = "Allows saved-plan uploads only under explicitly configured plan prefixes for ${each.key}."
  policy      = each.value.json
}

# ReadOnlyAccess is account-wide data-plane read, so explicitly deny the categories a plan never needs.
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

  # The AWS provider replaces managed policies when description changes. Preserve the attached
  # deny policy instead of detaching and recreating this security control for metadata alone.
  lifecycle {
    ignore_changes = [description]
  }
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
  description          = "Deploy role for ${each.key}; trust is scoped to configured exact GitHub OIDC subjects."
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust[each.key].json
  max_session_duration = 7200
  permissions_boundary = aws_iam_policy.project_boundary.arn
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

# The HML root uses a dedicated saved-plan role. It has no PowerUser attachment and is restricted
# to the HML state key, HML plan artifacts, the shared cluster read contract, the HML migration role,
# and one namespace-scoped Pod Identity association.
data "aws_iam_policy_document" "hml_deploy_trust" {
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
      variable = "${local.oidc_host}:sub"
      values   = ["${local.repo_subject["k8s-infra"]}:environment:staging"]
    }
  }
}

resource "aws_iam_role" "hml_deploy" {
  name                 = "gh-deploy-k8s-hml"
  path                 = var.iam_path
  description          = "Least-privilege HML saved-plan role; namespace access is scoped by its EKS access entry."
  assume_role_policy   = data.aws_iam_policy_document.hml_deploy_trust.json
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.project_boundary.arn
}

data "aws_iam_policy_document" "hml_deploy" {
  statement {
    sid       = "ListOnlyHmlBackendPrefix"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["k8s-infra/hml/terraform.tfstate*"]
    }
  }

  statement {
    sid = "ReadWriteOnlyHmlBackendAndNativeLock"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
    ]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/hml/terraform.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/hml/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid = "ReadAndConsumeOnlyHmlSavedPlans"
    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:DeleteObject", "s3:DeleteObjectVersion",
    ]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/apply/hml.tfplan",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/destroy/hml.tfplan",
    ]
  }

  statement {
    sid = "ReadAndConsumeOnlyHmlPlanManifests"
    actions = [
      "s3:GetObject", "s3:GetObjectVersion", "s3:DeleteObject", "s3:DeleteObjectVersion",
    ]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/apply/manifest-hml.json",
      "arn:${local.partition}:s3:::${var.state_bucket}/k8s-infra/staging/plans/*/destroy/manifest-hml.json",
    ]
  }

  statement {
    sid = "InspectPrivatePlanBucketControls"
    actions = [
      "s3:GetBucketLocation", "s3:GetBucketPublicAccessBlock", "s3:GetBucketOwnershipControls",
    ]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }

  statement {
    sid       = "DescribeOnlyTheSharedStagingCluster"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/auto-shop-staging"]
  }

  statement {
    sid       = "ReadOnlyTheHmlMigrationRole"
    actions   = ["iam:GetRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/auto-shop/auto-shop-staging-db-migrate-hml"]
  }

  statement {
    sid       = "CheckTheCurrentAwsAccount"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid     = "ReadOnlyHmlNetworkAndClusterParameters"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/auto-shop/staging/eks/cluster-name",
      "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/auto-shop/staging/network/vpc-cidr",
      "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/auto-shop/staging/network/rds-isolated-subnet-cidrs",
      "arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/auto-shop/staging/network/alb-subnet-cidrs",
    ]
  }

  statement {
    sid       = "CreateOnlyTheHmlMigrationAssociation"
    actions   = ["eks:CreatePodIdentityAssociation"]
    resources = ["arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/auto-shop-staging"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = ["hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/KubernetesNamespace"
      values   = ["auto-shop-hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Purpose"
      values   = ["db-migration"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["auto-shop"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ManagedBy"
      values   = ["Terraform"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Repository"
      values   = ["k8s-infra"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Stack"
      values   = ["hml"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["Project", "Environment", "ManagedBy", "Repository", "Stack", "KubernetesNamespace", "Purpose"]
    }
  }

  statement {
    sid = "ManageOnlyTaggedHmlMigrationAssociation"
    actions = [
      "eks:DescribePodIdentityAssociation",
      "eks:UpdatePodIdentityAssociation",
      "eks:DeletePodIdentityAssociation",
      "eks:ListTagsForResource",
    ]
    resources = [
      "arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:podidentityassociation/auto-shop-staging/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/KubernetesNamespace"
      values   = ["auto-shop-hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Purpose"
      values   = ["db-migration"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["auto-shop"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["Terraform"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Repository"
      values   = ["k8s-infra"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Stack"
      values   = ["hml"]
    }
  }

  statement {
    sid       = "PassOnlyHmlMigrationRoleToPodIdentity"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/auto-shop/auto-shop-staging-db-migrate-hml"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["pods.eks.amazonaws.com"]
    }
  }

  statement {
    sid       = "CreateOnlyTheHmlDatabaseBootstrapAssociation"
    actions   = ["eks:CreatePodIdentityAssociation"]
    resources = ["arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:cluster/auto-shop-staging"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Environment"
      values   = ["hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/KubernetesNamespace"
      values   = ["auto-shop-ops"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Purpose"
      values   = ["db-bootstrap"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = ["auto-shop"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/ManagedBy"
      values   = ["Terraform"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Repository"
      values   = ["k8s-infra"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Stack"
      values   = ["hml"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["Project", "Environment", "ManagedBy", "Repository", "Stack", "KubernetesNamespace", "Purpose"]
    }
  }

  statement {
    sid = "ManageOnlyTaggedHmlDatabaseBootstrapAssociation"
    actions = [
      "eks:DescribePodIdentityAssociation",
      "eks:UpdatePodIdentityAssociation",
      "eks:DeletePodIdentityAssociation",
      "eks:ListTagsForResource",
    ]
    resources = [
      "arn:${local.partition}:eks:${var.aws_region}:${local.account_id}:podidentityassociation/auto-shop-staging/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/KubernetesNamespace"
      values   = ["auto-shop-ops"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Purpose"
      values   = ["db-bootstrap"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = ["auto-shop"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/ManagedBy"
      values   = ["Terraform"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Repository"
      values   = ["k8s-infra"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Stack"
      values   = ["hml"]
    }
  }

  statement {
    sid       = "PassOnlyHmlDatabaseBootstrapRoleToPodIdentity"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/auto-shop/auto-shop-staging-db-bootstrap-hml"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "hml_deploy" {
  name   = "hml-saved-plan-only"
  role   = aws_iam_role.hml_deploy.name
  policy = data.aws_iam_policy_document.hml_deploy.json
}

# Dedicated HML lambda-auth role. It intentionally has backend-only permissions until the
# lambda-auth Terraform plan is reviewed and a least-privilege deployment policy is generated.
# The production generic deploy role is not trusted for HML and this role receives no PowerUser.
data "aws_iam_policy_document" "lambda_auth_hml_trust" {
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
      variable = "${local.oidc_host}:sub"
      values   = ["${local.repo_subject["lambda-auth"]}:environment:hml"]
    }
  }
}

resource "aws_iam_role" "lambda_auth_hml_deploy" {
  name                 = "gh-deploy-lambda-auth-hml"
  path                 = var.iam_path
  description          = "HML lambda-auth role; currently limited to the isolated HML Terraform state."
  assume_role_policy   = data.aws_iam_policy_document.lambda_auth_hml_trust.json
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.project_boundary.arn
}

data "aws_iam_policy_document" "lambda_auth_hml_state" {
  statement {
    sid       = "ReadBackendBucketLocation"
    actions   = ["s3:GetBucketLocation"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]
  }

  statement {
    sid       = "ListOnlyHmlBackendState"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.state_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["lambda-auth/hml/terraform.tfstate"]
    }
  }

  statement {
    sid = "ReadWriteOnlyHmlBackendAndNativeLock"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "arn:${local.partition}:s3:::${var.state_bucket}/lambda-auth/hml/terraform.tfstate",
      "arn:${local.partition}:s3:::${var.state_bucket}/lambda-auth/hml/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid       = "VerifyAwsAccount"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_auth_hml_state" {
  name   = "lambda-auth-hml-state-only"
  role   = aws_iam_role.lambda_auth_hml_deploy.name
  policy = data.aws_iam_policy_document.lambda_auth_hml_state.json
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

  # Within the boundary, allow only the IAM operations the HML deploy roles need for
  # their exact service roles. Generic deploy identities receive no new IAM allowance.
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

  statement {
    sid       = "AllowHmlLambdaCreateBoundedExecutionRole"
    actions   = ["iam:CreateRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}lambda-auth-hml-execution"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-lambda-auth-hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-boundary"]
    }
  }

  statement {
    sid = "AllowHmlLambdaManageExecutionRole"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}lambda-auth-hml-execution"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-lambda-auth-hml"]
    }
  }

  statement {
    sid     = "AllowK8sInfraCreateFoundationRoles"
    actions = ["iam:CreateRole"]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}k8s-infra-codebuild-private-runner",
      "arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}auto-shop-staging-cloudwatch-observability",
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-k8s-infra"]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = ["arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-boundary"]
    }
  }

  statement {
    sid = "AllowK8sInfraManageFoundationRoles"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}k8s-infra-codebuild-private-runner",
      "arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}auto-shop-staging-cloudwatch-observability",
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-k8s-infra"]
    }
  }

  statement {
    sid       = "AllowK8sInfraPassPrivateRunnerRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}k8s-infra-codebuild-private-runner"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-k8s-infra"]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["codebuild.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowK8sInfraPassObservabilityRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}auto-shop-staging-cloudwatch-observability"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-k8s-infra"]
    }

  }

  statement {
    sid       = "AllowHmlLambdaPassExecutionRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}lambda-auth-hml-execution"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-lambda-auth-hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  statement {
    sid       = "AllowHmlK8sPassMigrationRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/auto-shop/auto-shop-staging-db-migrate-hml"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-k8s-hml"]
    }

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["pods.eks.amazonaws.com"]
    }
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

    # Deploy roles need their own backend/lock files. Their per-repository identity policies retain
    # explicit denies outside each approved state prefix; this exception only prevents the boundary
    # from blocking those narrowly scoped grants.
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-*"]
    }
  }
}

resource "aws_iam_policy" "project_boundary" {
  name        = "auto-shop-boundary"
  path        = var.iam_path
  description = "Permissions boundary for every IAM role created under ${var.iam_path}."
  policy      = data.aws_iam_policy_document.project_boundary.json
}

data "aws_iam_policy_document" "deploy_iam" {
  # PowerUserAccess grants role chaining. This identity-policy Deny applies to deploy roles without
  # preventing their initial AssumeRoleWithWebIdentity exchange with GitHub OIDC.
  statement {
    sid       = "DenyRoleChaining"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }

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
      values = [
        "arn:${local.partition}:iam::${local.account_id}:policy${var.iam_path}auto-shop-boundary"
      ]
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
    sid       = "PassPrivateK8sRunnerRoleOnlyToCodeBuild"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/auto-shop/k8s-infra-codebuild-private-runner"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["codebuild.amazonaws.com"]
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

  # EKS checks the node-group service-linked role before creating a managed node group. Keep the
  # read grant limited to that exact role and the one deploy identity that needs it.
  statement {
    sid       = "ReadEksNodegroupServiceLinkedRole"
    actions   = ["iam:GetRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup"]

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:${local.partition}:iam::${local.account_id}:role${var.iam_path}gh-deploy-k8s-infra"]
    }
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
