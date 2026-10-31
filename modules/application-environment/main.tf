data "aws_ssm_parameter" "vpc_cidr" {
  name = "/auto-shop/staging/network/vpc-cidr"
}

data "aws_ssm_parameter" "rds_cidrs" {
  name = "/auto-shop/staging/network/rds-isolated-subnet-cidrs"
}

data "aws_ssm_parameter" "alb_cidrs" {
  name = "/auto-shop/staging/network/alb-subnet-cidrs"
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "db_migration_secret_read_policy_arn" {
  name = "/auto-shop/staging/database/iam/migrations-${var.environment}-read-policy-arn"
}

# This environment's own migration role, trust policy, and database-owned read policy. The
# namespace and service-account request tags prevent an HML pod from assuming the PRD role and
# vice versa, even though both roles share the same cluster.
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
      values   = ["auto-shop-${var.environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["auto-shop-migration"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
    }
  }
}

resource "aws_iam_role" "db_migration" {
  name                 = "auto-shop-staging-db-migrate-${var.environment}"
  path                 = "/auto-shop/"
  assume_role_policy   = data.aws_iam_policy_document.db_migration_pod_identity_trust.json
  permissions_boundary = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/auto-shop/auto-shop-boundary"
}

resource "aws_iam_role_policy_attachment" "db_migration_secret_read" {
  role       = aws_iam_role.db_migration.name
  policy_arn = data.aws_ssm_parameter.db_migration_secret_read_policy_arn.value
}

locals {
  namespace        = "auto-shop-${var.environment}"
  namespace_name   = var.create_namespace ? kubernetes_namespace_v1.app[0].metadata[0].name : data.kubernetes_namespace_v1.existing_app[0].metadata[0].name
  rds_cidrs        = split(",", data.aws_ssm_parameter.rds_cidrs.value)
  alb_subnet_cidrs = split(",", data.aws_ssm_parameter.alb_cidrs.value)

  pss_labels = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/warn"            = "restricted"
    "pod-security.kubernetes.io/audit"           = "restricted"
  }
}

resource "kubernetes_namespace_v1" "app" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = local.namespace
    labels = merge(local.pss_labels, {
      "app.kubernetes.io/part-of" = "auto-shop-platform"
      "auto-shop/environment"     = var.environment
    })
  }
}

data "kubernetes_namespace_v1" "existing_app" {
  count = var.create_namespace ? 0 : 1

  metadata {
    name = local.namespace
  }
}

resource "kubernetes_resource_quota_v1" "app" {
  metadata {
    name      = "compute"
    namespace = local.namespace_name
  }

  spec {
    hard = var.app_namespace_quota
  }
}

resource "kubernetes_limit_range_v1" "app" {
  metadata {
    name      = "defaults"
    namespace = local.namespace_name
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

# Lets the auto-shop-system deploy role manage only the namespaced CRDs it owns.
resource "kubernetes_role_v1" "deployer_crds" {
  count = var.environment == "hml" ? 0 : 1

  metadata {
    name      = "auto-shop-deployer-crds"
    namespace = local.namespace_name
  }

  rule {
    api_groups = ["elbv2.k8s.aws"]
    resources  = ["targetgroupbindings"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "deployer_crds" {
  count = var.environment == "hml" ? 0 : 1

  metadata {
    name      = "auto-shop-deployer-crds"
    namespace = local.namespace_name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.deployer_crds[0].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "auto-shop-deployers"
    api_group = "rbac.authorization.k8s.io"
  }
}

# Default deny from the first apply (k8s-infra#5): no application Pod runs before these policies.
resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# Limit this environment's migration Pods to the Pod Identity credential endpoint.
resource "kubernetes_network_policy_v1" "migration_pod_identity_agent" {
  metadata {
    name      = "allow-migration-pod-identity-agent"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "auto-shop-system"
        "app.kubernetes.io/component" = "migrate"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "169.254.170.23/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "80"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "dns" {
  metadata {
    name      = "allow-dns"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "postgres" {
  metadata {
    name      = "allow-egress-postgres"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      dynamic "to" {
        for_each = local.rds_cidrs
        content {
          ip_block {
            cidr = to.value
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "5432"
      }
    }
  }
}

# External APIs and AWS endpoints go through NAT. The rule excludes the VPC, so it cannot become
# a VPC-wide shortcut between the HML and PRD namespaces.
resource "kubernetes_network_policy_v1" "https" {
  metadata {
    name      = "allow-egress-https"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = [data.aws_ssm_parameter.vpc_cidr.value, "169.254.0.0/16"]
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {}
      }
    }

    egress {
      to {
        pod_selector {}
      }
    }
  }
}

# Only the internal ALB's dedicated subnets may reach the application port.
resource "kubernetes_network_policy_v1" "alb_ingress" {
  metadata {
    name      = "allow-alb-to-api"
    namespace = local.namespace_name
  }

  spec {
    pod_selector {
      match_labels = var.app_pod_selector
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = local.alb_subnet_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = tostring(var.app_port)
      }
    }
  }
}

resource "kubernetes_manifest" "app_runtime_store" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "auto-shop-app-runtime"
      namespace = local.namespace_name
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
        }
      }
    }
  }

}

resource "kubernetes_manifest" "app_runtime_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "auto-shop-secrets"
      namespace = local.namespace_name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "auto-shop-app-runtime"
        kind = "SecretStore"
      }
      target = {
        name           = "auto-shop-secrets"
        creationPolicy = "Owner"
      }
      dataFrom = [
        {
          extract = {
            key = "auto-shop/staging/${var.environment}/app-runtime"
          }
        }
      ]
    }
  }

  depends_on = [kubernetes_manifest.app_runtime_store]
}

resource "kubernetes_service_account_v1" "db_migration" {
  metadata {
    name      = "auto-shop-migration"
    namespace = local.namespace_name
    labels = {
      "app.kubernetes.io/name"      = "auto-shop-system"
      "app.kubernetes.io/component" = "migration"
      "auto-shop/environment"       = var.environment
    }
  }

}

resource "aws_eks_pod_identity_association" "db_migration" {
  cluster_name    = var.cluster_name
  namespace       = kubernetes_service_account_v1.db_migration.metadata[0].namespace
  service_account = kubernetes_service_account_v1.db_migration.metadata[0].name
  role_arn        = aws_iam_role.db_migration.arn
  tags = {
    Environment         = var.environment
    KubernetesNamespace = local.namespace
    Purpose             = "db-migration"
  }
}
