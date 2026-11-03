data "aws_ssm_parameter" "cluster_name" {
  name = "/auto-shop/staging/eks/cluster-name"
}

data "aws_eks_cluster" "this" {
  name = data.aws_ssm_parameter.cluster_name.value
}

locals {
  kube_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--region", var.aws_region, "--cluster-name", data.aws_eks_cluster.this.name]
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = {
      Project     = "auto-shop"
      Environment = "production"
      ManagedBy   = "Terraform"
      Repository  = "k8s-infra"
      Stack       = "production"
    }
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = local.kube_exec.api_version
    command     = local.kube_exec.command
    args        = local.kube_exec.args
  }
}

module "environment" {
  source = "../../modules/application-environment"

  environment      = "prd"
  aws_region       = var.aws_region
  cluster_name     = data.aws_eks_cluster.this.name
  create_namespace = true
}

# Production retains Terraform ownership of its migration ServiceAccount.
resource "kubernetes_service_account_v1" "db_migration" {
  metadata {
    name      = "auto-shop-migration"
    namespace = module.environment.namespace
    labels = {
      "app.kubernetes.io/name"      = "auto-shop-system"
      "app.kubernetes.io/component" = "migration"
      "auto-shop/environment"       = "prd"
    }
  }
}

# Keep the existing production ServiceAccount while moving its state out of the shared module.
moved {
  from = module.environment.kubernetes_service_account_v1.db_migration
  to   = kubernetes_service_account_v1.db_migration
}
