output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Command to configure kubectl."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ssm_parameters" {
  description = "Contract parameters published for the other repositories."
  value       = module.contract.parameter_names
}

output "internal_alb_listeners" {
  description = "Listener ARN per environment."
  value       = module.alb.listener_arns
}

output "target_group_arns" {
  description = "Target group ARN per environment (TargetGroupBinding)."
  value       = module.alb.target_group_arns
}
