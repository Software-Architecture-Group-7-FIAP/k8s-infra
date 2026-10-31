output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider shared by the four repositories."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arns" {
  description = "Role per repository for explicitly authorized Terraform plans (set as AWS_PLAN_ROLE_ARN repository variable)."
  value       = { for repo, role in aws_iam_role.plan : repo => role.arn }
}

output "deploy_role_arns" {
  description = "Role per repository for apply/deploy (set as AWS_DEPLOY_ROLE_ARN repository variable)."
  value       = { for repo, role in aws_iam_role.deploy : repo => role.arn }
}

output "hml_deploy_role_arn" {
  description = "Least-privilege saved-plan role for the HML environment root (set as AWS_HML_DEPLOY_ROLE_ARN in k8s-infra)."
  value       = aws_iam_role.hml_deploy.arn
}

output "orphan_audit_role_arn" {
  description = "Read-only GitHub OIDC role for the k8s-infra staging and environment-root orphan audit (set as AWS_AUDIT_ROLE_ARN)."
  value       = aws_iam_role.orphan_audit.arn
}

output "project_boundary_arn" {
  description = "Permissions boundary every role created under the project IAM path must carry. foundation and platform recompute this exact ARN locally instead of reading it, to avoid a terraform_remote_state dependency on this stack."
  value       = aws_iam_policy.project_boundary.arn
}
