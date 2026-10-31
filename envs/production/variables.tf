variable "aws_region" {
  description = "AWS region containing the shared staging infrastructure."
  type        = string
  default     = "us-east-1"
}

variable "expected_account_id" {
  description = "Guard against applying this environment root to another AWS account."
  type        = string
  default     = "035611741563"
}
