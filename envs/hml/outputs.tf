output "namespace" {
  description = "HML application namespace managed by this root."
  value       = module.environment.namespace
}

output "migration_service_account" {
  description = "HML database migration service account."
  value       = module.environment.migration_service_account
}
