data "aws_ssm_parameter" "db_migration_secret_read_policy_arn" {
  for_each = toset(local.app_environments)

  name = "/auto-shop/staging/database/iam/migrations-${each.key}-read-policy-arn"
}

# Each environment gets a distinct migration role, trust policy, and database-owned read policy.
# The namespace and service-account tags prevent an HML pod from assuming the PRD role and vice versa.
data "aws_iam_policy_document" "db_migration_pod_identity_trust" {
  for_each = toset(local.app_environments)

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["auto-shop-${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["auto-shop-migration"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [data.aws_eks_cluster.this.arn]
    }
  }
}

resource "aws_iam_role" "db_migration" {
  for_each = toset(local.app_environments)

  name                 = "auto-shop-staging-db-migrate-${each.key}"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.db_migration_pod_identity_trust[each.key].json
  permissions_boundary = local.project_boundary_arn
}

resource "aws_iam_role_policy_attachment" "db_migration_secret_read" {
  for_each = toset(local.app_environments)

  role       = aws_iam_role.db_migration[each.key].name
  policy_arn = data.aws_ssm_parameter.db_migration_secret_read_policy_arn[each.key].value
}
