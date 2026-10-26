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

variable "environments" {
  description = "Application environments; each one becomes the namespace auto-shop-<env>."
  type        = list(string)
  default     = ["hml", "prd"]
}

variable "app_port" {
  description = "FastAPI container port (ALB -> Pod)."
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

variable "chart_versions" {
  description = "Pinned Helm chart versions."
  type        = map(string)
  default = {
    aws_load_balancer_controller = "3.6.2"
    external_secrets             = "2.14.0"
  }
}

variable "app_namespace_quota" {
  description = "ResourceQuota per application namespace. Sized so hml + prd at HPA max (4 replicas each) fit in two t3.medium nodes."
  type        = map(string)
  default = {
    "requests.cpu"    = "1500m"
    "requests.memory" = "2Gi"
    "limits.memory"   = "3Gi"
    "pods"            = "15"
  }
}
