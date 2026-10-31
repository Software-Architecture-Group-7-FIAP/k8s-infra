data "aws_ssm_parameter" "vpc_cidr" {
  name = "/auto-shop/staging/network/vpc-cidr"
}

data "aws_ssm_parameter" "rds_cidrs" {
  name = "/auto-shop/staging/network/rds-isolated-subnet-cidrs"
}

locals {
  ops_namespace = "auto-shop-ops"
  rds_cidrs     = split(",", data.aws_ssm_parameter.rds_cidrs.value)

  pss_labels = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
    "pod-security.kubernetes.io/warn"            = "restricted"
    "pod-security.kubernetes.io/audit"           = "restricted"
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.ops_namespace
    labels = merge(local.pss_labels, {
      "app.kubernetes.io/part-of" = "auto-shop-platform"
      "auto-shop/environment"     = "ops"
    })
  }
}

resource "kubernetes_limit_range_v1" "this" {
  metadata {
    name      = "defaults"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
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

# The HML environment role may manage only its environment-specific database bootstrap
# ServiceAccount in the shared operations namespace. The AWS role association and ServiceAccount
# remain in the isolated HML Terraform state so its authorized destroy removes both.
resource "kubernetes_role_v1" "hml_database_bootstrap_identity" {
  metadata {
    name      = "hml-database-bootstrap-identity"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["create"]
  }

  rule {
    api_groups     = [""]
    resources      = ["serviceaccounts"]
    resource_names = ["auto-shop-db-bootstrap-hml"]
    verbs          = ["get", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "hml_database_bootstrap_identity" {
  metadata {
    name      = kubernetes_role_v1.hml_database_bootstrap_identity.metadata[0].name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "auto-shop-hml-infra"
    api_group = "rbac.authorization.k8s.io"
  }

  role_ref {
    kind      = "Role"
    name      = kubernetes_role_v1.hml_database_bootstrap_identity.metadata[0].name
    api_group = "rbac.authorization.k8s.io"
  }
}
