output "namespace" {
  description = "Application namespace used by this environment; HML reads its precreated namespace."
  value       = local.namespace_name
}

output "migration_service_account" {
  description = "Migration service account in this environment's namespace."
  value       = kubernetes_service_account_v1.db_migration.metadata[0].name
}
