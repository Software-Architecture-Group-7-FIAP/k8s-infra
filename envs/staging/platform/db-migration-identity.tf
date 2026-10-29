data "aws_ssm_parameter" "db_migration_owner_policy_arn" {
  name = "/auto-shop/staging/database/iam/owner-read-policy-arn"
}

data "aws_iam_policy_document" "db_migration_pod_identity_trust" {
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
      values   = ["auto-shop-ops"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["auto-shop-db-migrate"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [data.aws_eks_cluster.this.arn]
    }
  }
}

resource "aws_iam_role" "db_migration" {
  name                 = "auto-shop-staging-db-migrate"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.db_migration_pod_identity_trust.json
  permissions_boundary = local.project_boundary_arn
}

resource "aws_iam_role_policy_attachment" "db_migration_owner" {
  role       = aws_iam_role.db_migration.name
  policy_arn = data.aws_ssm_parameter.db_migration_owner_policy_arn.value
}

resource "kubernetes_service_account_v1" "db_migration" {
  metadata {
    name      = "auto-shop-db-migrate"
    namespace = kubernetes_namespace_v1.this["ops"].metadata[0].name
    labels = {
      "app.kubernetes.io/name"      = "auto-shop-system"
      "app.kubernetes.io/component" = "migration"
    }
  }
}

resource "aws_eks_pod_identity_association" "db_migration" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = kubernetes_service_account_v1.db_migration.metadata[0].namespace
  service_account = kubernetes_service_account_v1.db_migration.metadata[0].name
  role_arn        = aws_iam_role.db_migration.arn

  depends_on = [aws_iam_role_policy_attachment.db_migration_owner]
}
