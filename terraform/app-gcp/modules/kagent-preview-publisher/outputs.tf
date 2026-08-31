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

output "source_uri" {
  description = "Read-only public kagent fork URI cloned and independently verified by the build."
  value       = var.enabled ? var.github_remote_uri : null
}

output "trigger_id" {
  description = "Terraform-owned Pub/Sub-invoked kagent preview trigger ID, or null while disabled."
  value       = var.enabled ? google_cloudbuild_trigger.release[0].id : null
}

output "release_request_topic" {
  description = "IAM-protected Pub/Sub topic accepting reviewed kagent release requests, or null while disabled."
  value       = var.enabled ? google_pubsub_topic.release_request[0].id : null
}

output "artifact_repository_prefix" {
  description = "Artifact Registry prefix containing immutable kagent preview images and charts, or null while disabled."
  value       = var.enabled ? local.artifact_repository_prefix : null
}

output "ghcr_secret_id" {
  description = "Deprecated empty GHCR Secret Manager container retained for non-destructive migration; the trigger does not consume it."
  value       = var.enabled ? google_secret_manager_secret.ghcr_write[0].secret_id : null
}
