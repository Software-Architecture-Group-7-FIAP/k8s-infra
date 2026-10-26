data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  role_arn   = "arn:${local.partition}:iam::${local.account_id}:role/auto-shop"

  # Recomputed from the bootstrap stack's fixed name/path convention, not read via remote state
  # (see bootstrap/outputs.tf). Every role this stack creates must carry it (deploy_iam policy in
  # bootstrap requires iam:PermissionsBoundary on CreateRole for anything under /auto-shop/).
  project_boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/auto-shop/auto-shop-boundary"

  app_namespaces = [for env in keys(var.environments) : "auto-shop-${env}"]
  ops_namespace  = "auto-shop-ops"

  tags = {
    Project     = "auto-shop"
    Environment = "staging"
  }
}

# Keep the cluster-admin entry stable across plan (gh-plan) and apply (gh-deploy) identities. The
# EKS module previously keyed the same deploy entry as `cluster_creator`; move state in place.
moved {
  from = module.eks.aws_eks_access_entry.this["cluster_creator"]
  to   = module.eks.aws_eks_access_entry.this["k8s-infra-deploy"]
}

moved {
  from = module.eks.aws_eks_access_policy_association.this["cluster_creator_admin"]
  to   = module.eks.aws_eks_access_policy_association.this["k8s-infra-deploy_admin"]
}

module "network" {
  source = "../../../modules/network"

  name         = var.name
  cidr         = "10.80.0.0/20"
  azs          = var.azs
  cluster_name = var.name

  # ADR-0071 plan. 10.80.0.64/26 (former CodeBuild ranges) stays unallocated; 10.80.8.0/21 now hosts
  # the dedicated ALB subnets, leaving 10.80.8.64/27 onward free.
  public_subnets   = ["10.80.0.0/27", "10.80.0.32/27"]
  workload_subnets = ["10.80.2.0/23", "10.80.4.0/23"]
  isolated_subnets = ["10.80.6.0/24", "10.80.7.0/24"]
  alb_subnets      = ["10.80.8.0/27", "10.80.8.32/27"]

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.network.vpc_id
  subnet_ids               = module.network.workload_subnet_ids
  control_plane_subnet_ids = module.network.workload_subnet_ids

  # ADR-0071 revision 2026-10-25: public + private endpoint, IAM-authenticated; no CodeBuild runner.
  endpoint_public_access  = true
  endpoint_private_access = true

  # "audit" is the only log that records which admin principal did what; without it an incident via
  # the cluster-admin access entries below leaves no trail. Keep the one-day window from the plan;
  # the log group is destroyed with the cluster.
  enabled_log_types                      = ["api", "audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 1

  iam_role_path                 = "/auto-shop/"
  iam_role_permissions_boundary = local.project_boundary_arn
  node_iam_role_path            = "/auto-shop/"

  # No additional KMS envelope encryption of Secrets in this ephemeral, synthetic-data environment:
  # etcd is still encrypted by AWS's default EKS encryption. This removes a CMK that would otherwise
  # sit in PendingDeletion (and incur tiny but real cost) for 7 days after every session's teardown,
  # and the extra IAM policy EKS creates for it (which must also carry the boundary and was missing
  # it, breaking the very first apply). Revisit if a longer-lived environment needs it.
  create_kms_key    = false
  encryption_config = null

  enable_irsa         = true
  authentication_mode = "API"
  # Keep access entries independent of whether Terraform is running as the plan or deploy role.
  enable_cluster_creator_admin_permissions = false

  access_entries = merge(
    {
      for idx, arn in var.admin_principal_arns : "admin-${idx}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    {
      k8s-infra-deploy = {
        principal_arn = "${local.role_arn}/gh-deploy-k8s-infra"
        policy_associations = {
          admin = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
      k8s-infra-plan = {
        principal_arn = "${local.role_arn}/gh-plan-k8s-infra"
        policy_associations = {
          view = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
      app-deploy = {
        principal_arn     = "${local.role_arn}/gh-deploy-auto-shop-system"
        kubernetes_groups = ["auto-shop-deployers"]
        policy_associations = {
          edit = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = { type = "namespace", namespaces = local.app_namespaces }
          }
        }
      }
      database-deploy = {
        principal_arn = "${local.role_arn}/gh-deploy-database-infra"
        policy_associations = {
          edit = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = { type = "namespace", namespaces = [local.ops_namespace] }
          }
        }
      }
    }
  )

  addons = {
    vpc-cni = {
      addon_version  = var.addon_versions["vpc-cni"]
      most_recent    = false
      before_compute = true
      # Standard enforcement + explicit default-deny policies in project namespaces (strict mode would also
      # block kube-system add-ons that have no policies).
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      addon_version  = var.addon_versions["eks-pod-identity-agent"]
      most_recent    = false
      before_compute = true
    }
    kube-proxy = {
      addon_version = var.addon_versions["kube-proxy"]
      most_recent   = false
    }
    coredns = {
      addon_version = var.addon_versions["coredns"]
      most_recent   = false
    }
    metrics-server = {
      addon_version = var.addon_versions["metrics-server"]
      most_recent   = false
    }
  }

  # Node group parameters (maxPods, AMI, kubernetes_version) are effectively immutable within a
  # session: with the account's 5 vCPU quota and 2x 2-vCPU nodes already at the ceiling, an in-place
  # update would need EKS's usual surge capacity (up to 2x the AZ count) and simply never acquire it.
  # Change these by destroying and recreating the foundation stack, not by applying over a running one.
  eks_managed_node_groups = {
    spot = {
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "SPOT"
      instance_types = var.node_instance_types

      min_size     = var.node_count
      desired_size = var.node_count
      max_size     = var.node_count

      iam_role_path                 = "/auto-shop/"
      iam_role_permissions_boundary = local.project_boundary_arn

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 20
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  maxPods: ${var.node_max_pods}
          EOT
        }
      ]

      update_config = {
        max_unavailable = 1
      }
    }
  }

  tags = local.tags
}

module "alb" {
  source = "../../../modules/alb"

  name     = var.name
  vpc_id   = module.network.vpc_id
  vpc_cidr = module.network.vpc_cidr
  # Dedicated subnets (not shared with node/Pod ENIs) so the platform stack's NetworkPolicy can
  # narrow ALB-to-Pod ingress to exactly these two CIDRs instead of the whole VPC — otherwise any
  # pod, not just the ALB, would match an "allow from the VPC" rule.
  subnet_ids             = module.network.alb_subnet_ids
  node_security_group_id = module.eks.node_security_group_id
  app_port               = var.app_port
  environments           = var.environments

  tags = local.tags
}

module "contract" {
  source = "../../../modules/ssm-contract"

  prefix = "/auto-shop/staging"

  strings = merge(
    {
      "network/vpc-id"                      = module.network.vpc_id
      "network/vpc-cidr"                    = module.network.vpc_cidr
      "network/eks-node-security-group-id"  = module.eks.node_security_group_id
      "network/lambda-security-group-id"    = module.network.lambda_security_group_id
      "eks/cluster-name"                    = module.eks.cluster_name
      "eks/cluster-endpoint"                = module.eks.cluster_endpoint
      "eks/oidc-provider-arn"               = module.eks.oidc_provider_arn
      "gateway/internal-alb-arn"            = module.alb.alb_arn
      "gateway/internal-alb-dns"            = module.alb.alb_dns_name
      "gateway/internal-alb-security-group" = module.alb.security_group_id
      "domain/root"                         = var.root_domain
      "domain/api-url"                      = "https://api.${var.root_domain}"
      "domain/frontend-url/prd"             = "https://app.${var.root_domain}"
      "domain/frontend-url/hml"             = "https://app-hml.${var.root_domain}"
    },
    { for env, arn in module.alb.listener_arns : "gateway/listener-arn/${env}" => arn },
    { for env, port in var.environments : "gateway/listener-port/${env}" => tostring(port) },
    { for env, arn in module.alb.target_group_arns : "gateway/target-group-arn/${env}" => arn },
  )

  lists = {
    "network/workload-private-subnet-ids" = module.network.workload_subnet_ids
    "network/rds-isolated-subnet-ids"     = module.network.isolated_subnet_ids
    "network/rds-isolated-subnet-cidrs"   = module.network.isolated_subnet_cidrs
    "network/alb-subnet-cidrs"            = module.network.alb_subnet_cidrs
  }

  tags = local.tags
}
