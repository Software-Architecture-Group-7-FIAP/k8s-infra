# Each environment can read only its own app-runtime secret. The namespace
# labels used by these conditions are owned by this Terraform stack.
resource "kubernetes_manifest" "app_runtime_store" {
  for_each = local.app_namespaces

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "auto-shop-app-runtime-${each.key}"
    }
    spec = {
      conditions = [
        {
          namespaceSelector = {
            matchLabels = {
              "auto-shop/environment" = each.key
            }
          }
        }
      ]
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
        }
      }
    }
  }

  depends_on = [
    helm_release.eso,
    aws_eks_pod_identity_association.eso,
    aws_iam_role_policy.eso,
  ]
}

resource "kubernetes_manifest" "app_runtime_external_secret" {
  for_each = local.app_namespaces

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "auto-shop-secrets"
      namespace = each.value
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = kubernetes_manifest.app_runtime_store[each.key].object.metadata.name
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "auto-shop-secrets"
        creationPolicy = "Owner"
      }
      dataFrom = [
        {
          extract = {
            key = "auto-shop/staging/${each.key}/app-runtime"
          }
        }
      ]
    }
  }
}
