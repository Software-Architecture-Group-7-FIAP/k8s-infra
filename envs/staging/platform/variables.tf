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

variable "chart_versions" {
  description = "Pinned Helm chart versions."
  type        = map(string)
  default = {
    aws_load_balancer_controller = "3.6.2"
    external_secrets             = "2.14.0"
  }
}
