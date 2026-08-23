output "connection_id" {
  description = "Fully-qualified ID of the shared, out-of-band Cloud Build v2 connection."
  value       = local.connection_id
}

output "repository_id" {
  description = "Cloud Build v2 repository link for pilprod/yourown-chat-kagent."
  value       = google_cloudbuildv2_repository.this.id
}

output "trigger_id" {
  description = "Immutable preview-tag Cloud Build trigger ID."
  value       = google_cloudbuild_trigger.preview.id
}

output "build_service_account_email" {
  description = "Dedicated least-privilege kagent preview build/release identity."
  value       = google_service_account.build.email
}

output "source_bucket_name" {
  description = "Dedicated short-lived bucket for frozen kagent preview source and evidence."
  value       = google_storage_bucket.source.name
}

output "crds_ready" {
  description = "Whether the one-time current-main CRD bootstrap has been declared verified."
  value       = var.crds_ready
}

output "substrate_ready" {
  description = "Whether the irreversible GKE beta API and external Substrate runtime prerequisite has been declared verified."
  value       = var.substrate_ready
}
