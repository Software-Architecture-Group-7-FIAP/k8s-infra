resource "kubernetes_service_account_v1" "database_bootstrap" {
  metadata {
    name      = "auto-shop-db-bootstrap-hml"
    namespace = "auto-shop-ops"
    labels = {
      "app.kubernetes.io/name"      = "auto-shop-db-bootstrap"
      "app.kubernetes.io/component" = "database-bootstrap"
      "auto-shop/environment"       = "hml"
    }
  }
}

resource "aws_eks_pod_identity_association" "database_bootstrap" {
  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = kubernetes_service_account_v1.database_bootstrap.metadata[0].namespace
  service_account = kubernetes_service_account_v1.database_bootstrap.metadata[0].name
  role_arn        = "arn:aws:iam::${var.expected_account_id}:role/auto-shop/auto-shop-staging-db-bootstrap-hml"

  tags = {
    Project             = "auto-shop"
    Environment         = "hml"
    ManagedBy           = "Terraform"
    Repository          = "k8s-infra"
    Stack               = "hml"
    KubernetesNamespace = "auto-shop-ops"
    Purpose             = "db-bootstrap"
  }
}
