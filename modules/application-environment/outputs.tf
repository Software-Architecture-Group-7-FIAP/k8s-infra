output "namespace" {
  description = "Application namespace used by this environment; HML reads its precreated namespace."
  value       = local.namespace_name
}

output "migration_service_account" {
  description = "Migration service account in this environment's namespace."
  value       = "auto-shop-migration"
}
