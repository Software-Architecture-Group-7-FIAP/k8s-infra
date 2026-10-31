data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/auto-shop/staging/network/vpc-id"
}

locals {
  app_environments = ["hml", "prd"]
  eso_environments = {
    for env in local.app_environments : env => {
      app_namespace        = "auto-shop-${env}"
      controller_namespace = "external-secrets-${env}"
      runtime_secret_name  = "auto-shop/staging/${env}/app-runtime"
    }
  }
  eso_scoped_values = {
    scopedRBAC                   = true
    processClusterExternalSecret = false
    processClusterStore          = false
    processClusterGenerator      = false
    processClusterPushSecret     = false
    processPushSecret            = false
    processSecretStore           = true
    crds = {
      createClusterExternalSecret = false
      createClusterSecretStore    = false
      createClusterGenerator      = false
      createClusterPushSecret     = false
      createSecretStore           = true
      createPushSecret            = false
    }
    rbac = {
      serviceAccountTokenCreate = false
      servicebindings           = { create = false }
      aggregateToView           = false
      aggregateToEdit           = false
      aggregateToAdmin          = false
    }
  }

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
  for_each = local.eso_environments

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
      values   = [each.value.controller_namespace]
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

# --- External Secrets Operator: one controller and IAM identity per application environment.

data "aws_iam_policy_document" "eso" {
  for_each = local.eso_environments

  statement {
    sid     = "ReadAppRuntimeSecretsOnly"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    # Naming contract with database-infra: auto-shop/staging/<env>/app-runtime (AWS appends a random suffix).
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${each.value.runtime_secret_name}-*"]
  }
}

resource "kubernetes_namespace_v1" "eso" {
  for_each = local.eso_environments

  metadata {
    name = each.value.controller_namespace
    labels = {
      "app.kubernetes.io/part-of"                  = "auto-shop-platform"
      "auto-shop/environment"                      = each.key
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/audit"           = "restricted"
    }
  }
}

resource "aws_iam_role" "eso" {
  for_each = local.eso_environments

  name                 = "auto-shop-staging-external-secrets-${each.key}"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.eso_pod_identity_trust[each.key].json
  permissions_boundary = local.project_boundary_arn
}

resource "aws_iam_role_policy" "eso" {
  for_each = local.eso_environments

  name   = "read-${each.key}-app-runtime-secret"
  role   = aws_iam_role.eso[each.key].id
  policy = data.aws_iam_policy_document.eso[each.key].json
}

resource "aws_eks_pod_identity_association" "eso" {
  for_each = local.eso_environments

  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = each.value.controller_namespace
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso[each.key].arn

  depends_on = [aws_iam_role_policy.eso]
}

resource "helm_release" "eso_hml" {
  name       = "external-secrets-hml"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.chart_versions.external_secrets
  namespace  = local.eso_environments["hml"].controller_namespace
  wait       = true
  timeout    = 600

  values = [yamlencode(merge(local.eso_scoped_values, {
    installCRDs     = true
    scopedNamespace = local.eso_environments["hml"].app_namespace
    replicaCount    = 1
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
  }))]

  depends_on = [
    aws_eks_pod_identity_association.eso["hml"],
    aws_iam_role_policy.eso["hml"],
    kubernetes_namespace_v1.eso["hml"],
  ]
}

resource "helm_release" "eso_prd" {
  name       = "external-secrets-prd"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.chart_versions.external_secrets
  namespace  = local.eso_environments["prd"].controller_namespace
  wait       = true
  timeout    = 600

  values = [yamlencode(merge(local.eso_scoped_values, {
    installCRDs     = false
    scopedNamespace = local.eso_environments["prd"].app_namespace
    replicaCount    = 1
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
  }))]

  depends_on = [
    helm_release.eso_hml,
    aws_eks_pod_identity_association.eso["prd"],
    aws_iam_role_policy.eso["prd"],
    kubernetes_namespace_v1.eso["prd"],
  ]
}
