variable "name" {
  description = "Name prefix for every network resource."
  type        = string
}

variable "cidr" {
  description = "VPC IPv4 CIDR (ADR-0071: 10.80.0.0/20)."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0))
    error_message = "cidr must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "Exactly two Availability Zone names."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "ADR-0071 fixes exactly two Availability Zones."
  }
}

variable "public_subnets" {
  description = "Public subnets (NAT only), one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.public_subnets) == 2
    error_message = "One public subnet per AZ is required."
  }
}

variable "workload_subnets" {
  description = "Private subnets for EKS nodes, internal ALB and Lambda ENIs, one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.workload_subnets) == 2
    error_message = "One workload subnet per AZ is required."
  }
}

variable "isolated_subnets" {
  description = "Isolated subnets for RDS (no default route), one per AZ."
  type        = list(string)

  validation {
    condition     = length(var.isolated_subnets) == 2
    error_message = "One isolated subnet per AZ is required."
  }
}

variable "alb_subnets" {
  description = <<-EOT
    Dedicated subnets for the internal ALB only (no default route; ALB only needs intra-VPC
    traffic). Kept separate from workload_subnets so the ALB-to-Pod NetworkPolicy ipBlock can be
    narrowed to exactly these two CIDRs instead of the whole VPC — otherwise any pod in any
    namespace, not just the ALB, would match the "allow ingress from the VPC" rule and defeat the
    hml/prd NetworkPolicy isolation on the application port.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alb_subnets) == 2
    error_message = "One ALB subnet per AZ is required."
  }
}

variable "cluster_name" {
  description = "EKS cluster name used in subnet discovery tags."
  type        = string
}

variable "tags" {
  description = "Extra tags for every resource."
  type        = map(string)
  default     = {}
}
