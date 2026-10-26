output "vpc_id" {
  description = "VPC ID."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC IPv4 CIDR."
  value       = module.vpc.vpc_cidr_block
}

output "workload_subnet_ids" {
  description = "Private workload subnets (EKS nodes, internal ALB, Lambda)."
  value       = module.vpc.private_subnets
}

output "isolated_subnet_ids" {
  description = "Isolated subnets for RDS."
  value       = module.vpc.database_subnets
}

output "isolated_subnet_cidrs" {
  description = "Isolated subnet CIDRs (used by NetworkPolicy egress to PostgreSQL)."
  value       = module.vpc.database_subnets_cidr_blocks
}

output "public_subnet_ids" {
  description = "Public subnets (NAT)."
  value       = module.vpc.public_subnets
}

output "nat_gateway_count" {
  description = "Number of NAT gateways (expected 1)."
  value       = length(module.vpc.natgw_ids)
}

output "lambda_security_group_id" {
  description = "Security group for lambda-auth ENIs."
  value       = aws_security_group.lambda.id
}

output "alb_subnet_ids" {
  description = "Dedicated subnets for the internal ALB (not shared with EKS node/Pod ENIs)."
  value       = module.vpc.intra_subnets
}

output "alb_subnet_cidrs" {
  description = "ALB subnet CIDRs (used to narrow the ALB-to-Pod NetworkPolicy ipBlock)."
  value       = module.vpc.intra_subnets_cidr_blocks
}
