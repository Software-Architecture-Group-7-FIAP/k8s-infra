output "namespace" {
  description = "PRD application namespace managed by this root."
  value       = module.environment.namespace
}

output "migration_service_account" {
  description = "PRD database migration service account."
  value       = module.environment.migration_service_account
}
