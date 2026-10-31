variable "environment" {
  description = "Application environment represented by this isolated Terraform root."
  type        = string

  validation {
    condition     = contains(["hml", "prd"], var.environment)
    error_message = "The environment must be hml or prd."
  }
}

variable "aws_region" {
  description = "AWS region containing the shared staging EKS cluster and database network."
  type        = string
}

variable "cluster_name" {
  description = "Name of the shared staging EKS cluster from the foundation SSM contract."
  type        = string
}

variable "create_namespace" {
  description = "Whether this root creates its namespace. HML requires a separately authorized namespace bootstrap before the HML-only deploy role can run."
  type        = bool
  default     = true
}

variable "app_port" {
  description = "FastAPI container port allowed from the internal ALB subnets."
  type        = number
  default     = 8000
}

variable "app_pod_selector" {
  description = "Labels of the FastAPI Pods (k8s/base/app/deployment.yaml in auto-shop-system)."
  type        = map(string)
  default = {
    app = "auto-shop-backend"
  }
}

variable "app_namespace_quota" {
  description = "ResourceQuota for this application environment."
  type        = map(string)
  default = {
    "requests.cpu"    = "1500m"
    "requests.memory" = "2Gi"
    "limits.memory"   = "3Gi"
    "pods"            = "15"
  }
}
