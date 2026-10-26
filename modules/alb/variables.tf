variable "name" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR allowed to reach the listeners (VPC Link V2 ENIs live inside the VPC)."
  type        = string
}

variable "subnet_ids" {
  description = "Private workload subnets for the internal ALB."
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group; Pods use it because Security Groups for Pods are not supported on t3."
  type        = string
}

variable "app_port" {
  description = "Container port of the FastAPI application."
  type        = number
  default     = 8000
}

variable "environments" {
  description = "Environment name to listener port. Each environment gets its own listener and IP target group."
  type        = map(number)

  validation {
    condition     = length(distinct(values(var.environments))) == length(var.environments)
    error_message = "Each environment needs a distinct listener port."
  }
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
