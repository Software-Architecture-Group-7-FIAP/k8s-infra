variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = "Guard against applying to the wrong AWS account."
  type        = string
  default     = "035611741563"
}

variable "name" {
  description = "Name prefix and EKS cluster name."
  type        = string
  default     = "auto-shop-staging"
}

variable "azs" {
  description = "Two AZs. us-east-1a = use1-az1 and us-east-1b = use1-az2 in account 035611741563 (use1-az3 excluded)."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "kubernetes_version" {
  description = "EKS version in standard support (ADR-0071)."
  type        = string
  default     = "1.37"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted administrator CIDRs allowed to reach the public EKS Kubernetes API endpoint."
  type        = list(string)
  nullable    = false

  validation {
    condition = (
      length(var.cluster_endpoint_public_access_cidrs) > 0 &&
      length(distinct(var.cluster_endpoint_public_access_cidrs)) == length(var.cluster_endpoint_public_access_cidrs) &&
      alltrue([
        for cidr in var.cluster_endpoint_public_access_cidrs :
        can(cidrnetmask(cidr)) && try(
          cidrsubnet(cidr, 0, 0) == cidr && tonumber(split("/", cidr)[1]) > 0,
          false
        )
      ])
    )
    error_message = "Provide unique, canonical IPv4 administrator CIDRs with prefixes from /1 to /32."
  }
}

variable "enable_private_eks_runner" {
  description = "Create the private VPC runner used only by coordinator-authorized HML/platform workflows."
  type        = bool
  default     = false
}

variable "github_runner_group_id" {
  description = "ID of the organization runner group restricted to the three private cluster workflow files."
  type        = number
  default     = 0

  validation {
    condition     = !var.enable_private_eks_runner || (var.github_runner_group_id > 1 && floor(var.github_runner_group_id) == var.github_runner_group_id)
    error_message = "Enabling the private EKS runner requires a custom integer GitHub organization runner-group ID greater than 1."
  }
}

variable "github_codeconnection_arn" {
  description = "ARN of an AVAILABLE GitHub CodeConnections connection authorized for the Software-Architecture-Group-7-FIAP organization."
  type        = string
  default     = ""

  validation {
    condition = !var.enable_private_eks_runner || can(regex(
      "^arn:aws:(codeconnections|codestar-connections):${var.aws_region}:035611741563:connection/[A-Za-z0-9-]+$",
      var.github_codeconnection_arn
    ))
    error_message = "Enabling the private EKS runner requires a valid GitHub CodeConnections connection ARN."
  }
}

variable "addon_versions" {
  description = "Pinned EKS add-on versions for Kubernetes 1.37 (checked 2026-10-25 with DescribeAddonVersions)."
  type        = map(string)
  default = {
    "vpc-cni"                = "v1.23.2-eksbuild.8"
    "coredns"                = "v1.14.7-eksbuild.22"
    "kube-proxy"             = "v1.37.0-eksbuild.32"
    "eks-pod-identity-agent" = "v1.4.1-eksbuild.2"
    "metrics-server"         = "v0.9.0-eksbuild.14"
  }
}

variable "node_instance_types" {
  description = "On-Demand node group instance types (2 vCPU each; account quota is 5 vCPU)."
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]
}

variable "node_count" {
  description = "Fixed node count (min = desired = max). No Cluster Autoscaler in this phase."
  type        = number
  default     = 2

  validation {
    condition     = var.node_count >= 1 && var.node_count <= 2
    error_message = "With a 5 vCPU quota and 2 vCPU nodes, at most 2 nodes fit."
  }
}

variable "enable_nat_gateway" {
  description = "Keep the shared NAT gateway during an active session; set false during scheduled teardown."
  type        = bool
  default     = true
}

variable "node_max_pods" {
  description = "Kubelet maxPods with prefix delegation. Kept low because kube-reserved memory grows 11 MiB per pod."
  type        = number
  default     = 40
}

variable "app_port" {
  description = "FastAPI container port."
  type        = number
  default     = 8000
}

variable "environments" {
  description = "Application environment to internal ALB listener port (API Gateway integration contract)."
  type        = map(number)
  default = {
    hml = 8001
    prd = 8002
  }
}

variable "admin_principal_arns" {
  description = "Humans with cluster-admin access entries."
  type        = list(string)
  default     = ["arn:aws:iam::035611741563:user/gustavo-ferreira"]
}

variable "root_domain" {
  description = "Public domain controlled by the group (DNS at Registro.br)."
  type        = string
  default     = "oficina-workshop.com.br"
}
