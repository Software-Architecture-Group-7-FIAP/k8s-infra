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
      Environment = "hml"
      ManagedBy   = "Terraform"
      Repository  = "k8s-infra"
      Stack       = "hml"
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

  environment      = "hml"
  aws_region       = var.aws_region
  cluster_name     = data.aws_eks_cluster.this.name
  create_namespace = false
}

