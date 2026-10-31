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

output "ssm_contract" {
  description = "Sensitive-to-logs plain SSM contract payload used only by the post-apply verifier."
  value       = module.contract.parameter_contract
  sensitive   = true
}

output "internal_alb_listeners" {
  description = "Listener ARN per environment."
  value       = module.alb.listener_arns
}

output "target_group_arns" {
  description = "Target group ARN per environment (TargetGroupBinding)."
  value       = module.alb.target_group_arns
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatch operations dashboard for EKS, workloads, HPA and ALB."
  value       = aws_cloudwatch_dashboard.staging.dashboard_name
}

output "cloudwatch_observability_addon_version" {
  description = "Latest CloudWatch Observability add-on version compatible with this EKS version."
  value       = data.aws_eks_addon_version.cloudwatch_observability.version
}

output "cloudwatch_alarm_names" {
  description = "CloudWatch alarm names created for EKS, HPA, workloads and ALB health."
  value = concat(
    [
      aws_cloudwatch_metric_alarm.eks_api_server_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.eks_unschedulable_pods.alarm_name,
      aws_cloudwatch_metric_alarm.hpa_scaling_limited.alarm_name,
      aws_cloudwatch_metric_alarm.failed_workload_pods.alarm_name
    ],
    [for alarm in aws_cloudwatch_metric_alarm.alb_unhealthy_targets : alarm.alarm_name]
  )
}
