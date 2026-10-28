data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/auto-shop/staging/network/vpc-id"
}

locals {
  # Recomputed from the bootstrap stack's fixed name/path convention (see foundation/main.tf for the
  # same pattern) rather than read via remote state.
  project_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/auto-shop/auto-shop-boundary"
}

# The cluster ARN prevents cross-cluster use. Each role also pins the namespace and ServiceAccount
# request tags so another association on this cluster cannot reuse the controller roles.
data "aws_iam_policy_document" "lbc_pod_identity_trust" {
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
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [data.aws_eks_cluster.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["kube-system"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["aws-load-balancer-controller"]
    }
  }
}

data "aws_iam_policy_document" "eso_pod_identity_trust" {
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
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [data.aws_eks_cluster.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = ["external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-secrets"]
    }
  }
}

# --- AWS Load Balancer Controller: only TargetGroupBinding reconciliation (RegisterTargets/
# DeregisterTargets + read-only Describe calls). The ALB, listeners and target groups themselves are
# created by the foundation stack's Terraform, not by the controller, so this is NOT the full
# upstream IAM policy AWS publishes for Ingress/Service support — see the file for exactly what it
# grants.

resource "aws_iam_role" "lbc" {
  name                 = "auto-shop-staging-aws-load-balancer-controller"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.lbc_pod_identity_trust.json
  permissions_boundary = local.project_boundary_arn
}

resource "aws_iam_policy" "lbc" {
  name   = "auto-shop-staging-aws-load-balancer-controller"
  path   = "/auto-shop/"
  policy = file("${path.module}/policies/aws-load-balancer-controller-v3.6.2.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName                 = data.aws_eks_cluster.this.name
    region                      = var.aws_region
    vpcId                       = data.aws_ssm_parameter.vpc_id.value
    replicaCount                = 1
    enableServiceMutatorWebhook = false
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    resources = {
      requests = { cpu = "50m", memory = "96Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [aws_eks_pod_identity_association.lbc, aws_iam_role_policy_attachment.lbc]
}

# --- External Secrets Operator: reads only the app-runtime secrets of each environment.

resource "aws_iam_role" "eso" {
  name                 = "auto-shop-staging-external-secrets"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.eso_pod_identity_trust.json
  permissions_boundary = local.project_boundary_arn
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid     = "ReadAppRuntimeSecretsOnly"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    # Naming contract with database-infra: auto-shop/staging/<env>/app-runtime (AWS appends a random suffix).
    resources = [
      for env in var.environments :
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:auto-shop/staging/${env}/app-runtime-*"
    ]
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "read-app-runtime-secrets"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso.json
}

resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}

resource "helm_release" "eso" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_versions.external_secrets
  namespace        = "external-secrets"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    crds         = { enabled = true } # chart >=0.10 renamed installCRDs to crds.enabled
    replicaCount = 1
    serviceAccount = {
      create = true
      name   = "external-secrets"
    }
    resources = {
      requests = { cpu = "25m", memory = "64Mi" }
      limits   = { memory = "192Mi" }
    }
    webhook = {
      replicaCount = 1
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
    certController = {
      replicaCount = 1
      resources = {
        requests = { cpu = "10m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
  })]

  depends_on = [aws_eks_pod_identity_association.eso]
}
