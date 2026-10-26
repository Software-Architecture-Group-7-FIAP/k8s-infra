output "namespaces" {
  description = "Namespaces created by the platform stack."
  value       = { for k, ns in kubernetes_namespace_v1.this : k => ns.metadata[0].name }
}

output "external_secrets_role_arn" {
  description = "Pod Identity role of External Secrets (reads auto-shop/staging/<env>/app-runtime only)."
  value       = aws_iam_role.eso.arn
}

output "load_balancer_controller_role_arn" {
  description = "Pod Identity role of the AWS Load Balancer Controller."
  value       = aws_iam_role.lbc.arn
}
