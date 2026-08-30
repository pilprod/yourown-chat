output "enabled" {
  description = "Whether the dedicated preview publication resources are materialized."
  value       = var.enabled
}

output "service_account_email" {
  description = "Dedicated publisher service-account email, or null while disabled."
  value       = var.enabled ? google_service_account.publisher[0].email : null
}

output "evidence_bucket_name" {
  description = "Private versioned evidence bucket name, or null while disabled."
  value       = var.enabled ? google_storage_bucket.evidence[0].name : null
}

output "ghcr_secret_id" {
  description = "Empty Secret Manager container ID for the dedicated GHCR token, or null while disabled."
  value       = var.enabled ? google_secret_manager_secret.ghcr_write[0].secret_id : null
}
