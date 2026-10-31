# Default deny from the first apply (k8s-infra#5): nothing runs in these namespaces before the policies exist.

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "dns" {
  metadata {
    name      = "allow-dns"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
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
    namespace = kubernetes_namespace_v1.this.metadata[0].name
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

# External APIs (Invertexto, BrasilAPI), JWKS on the public API domain and AWS APIs, all through the
# NAT. Scoped to outside the VPC: pods already have narrower, explicit rules for anything inside it
# (DNS, PostgreSQL, same-namespace, ALB); this rule must not also become a VPC-wide pod-to-pod or
# pod-to-API-server shortcut.
resource "kubernetes_network_policy_v1" "https" {
  metadata {
    name      = "allow-egress-https"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
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

# Bootstrap Jobs in auto-shop-ops use EKS Pod Identity. Permit only the node-local agent endpoint;
# the general HTTPS policy above deliberately excludes all other link-local destinations.
resource "kubernetes_network_policy_v1" "pod_identity_agent" {
  metadata {
    name      = "allow-pod-identity-agent"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    pod_selector {}
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

      ports {
        protocol = "TCP"
        port     = "2703"
      }
    }
  }
}

# Limit HML/PRD migration Pods to the Pod Identity credential endpoint.
resource "kubernetes_network_policy_v1" "migration_pod_identity_agent" {
  for_each = local.app_namespaces

  metadata {
    name      = "allow-migration-pod-identity-agent"
    namespace = kubernetes_namespace_v1.this[each.key].metadata[0].name
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

# App <-> Redis/MailHog stay inside the namespace. In auto-shop-ops this is also what allows a
# migration/bootstrap Job's own components (if any) to talk to each other; hml and prd never reach
# each other because each namespace only matches its own pods.
resource "kubernetes_network_policy_v1" "same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
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
