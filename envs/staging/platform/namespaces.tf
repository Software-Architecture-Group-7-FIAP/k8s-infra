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
