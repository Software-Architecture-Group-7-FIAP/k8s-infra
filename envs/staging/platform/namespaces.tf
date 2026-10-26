data "aws_ssm_parameter" "vpc_cidr" {
  name = "/auto-shop/staging/network/vpc-cidr"
}

data "aws_ssm_parameter" "rds_cidrs" {
  name = "/auto-shop/staging/network/rds-isolated-subnet-cidrs"
}

data "aws_ssm_parameter" "alb_cidrs" {
  name = "/auto-shop/staging/network/alb-subnet-cidrs"
}

locals {
  app_namespaces = { for env in var.environments : env => "auto-shop-${env}" }
  ops_namespace  = "auto-shop-ops"

  # Namespaces that get default-deny plus DNS/PostgreSQL/HTTPS egress.
  all_namespaces = merge(local.app_namespaces, { ops = local.ops_namespace })

  rds_cidrs        = split(",", data.aws_ssm_parameter.rds_cidrs.value)
  alb_subnet_cidrs = split(",", data.aws_ssm_parameter.alb_cidrs.value)

  pss_labels = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/warn"            = "restricted"
    "pod-security.kubernetes.io/audit"           = "restricted"
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.all_namespaces

  metadata {
    name = each.value
    labels = merge(local.pss_labels, {
      "app.kubernetes.io/part-of" = "auto-shop-platform"
      "auto-shop/environment"     = each.key
    })
  }
}

resource "kubernetes_resource_quota_v1" "app" {
  for_each = local.app_namespaces

  metadata {
    name      = "compute"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    hard = var.app_namespace_quota
  }
}

resource "kubernetes_limit_range_v1" "this" {
  for_each = local.all_namespaces

  metadata {
    name      = "defaults"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "100m"
        memory = "128Mi"
      }
      max = {
        memory = "1Gi"
      }
    }
  }
}

# Lets the auto-shop-system deploy role (EKS access entry group) manage the CRDs it owns in its namespaces.
resource "kubernetes_role_v1" "deployer_crds" {
  for_each = local.app_namespaces

  metadata {
    name      = "auto-shop-deployer-crds"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  rule {
    api_groups = ["elbv2.k8s.aws"]
    resources  = ["targetgroupbindings"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets", "secretstores"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "deployer_crds" {
  for_each = local.app_namespaces

  metadata {
    name      = "auto-shop-deployer-crds"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer_crds[each.key].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "auto-shop-deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}
