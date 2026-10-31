output "namespaces" {
  description = "Shared operations namespace created by the platform stack."
  value       = { ops = kubernetes_namespace_v1.this.metadata[0].name }
}

output "external_secrets_role_arns" {
  description = "Pod Identity role ARNs keyed by environment; each reads only that environment's app-runtime secret."
  value       = { for environment, role in aws_iam_role.eso : environment => role.arn }
}

output "load_balancer_controller_role_arn" {
  description = "Pod Identity role of the AWS Load Balancer Controller."
  value       = aws_iam_role.lbc.arn
}

output "application_image_repository_url" {
  description = "Immutable-tag ECR repository used by auto-shop-system."
  value       = aws_ecr_repository.auto_shop_system.repository_url
}
