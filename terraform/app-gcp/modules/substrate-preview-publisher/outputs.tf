output "enabled" {
  description = "Whether the private Substrate publisher is materialized."
  value       = var.enabled
}

output "service_account_email" {
  description = "Dedicated publisher service-account email, or null while disabled."
  value       = var.enabled ? google_service_account.publisher[0].email : null
}

output "trigger_id" {
  description = "Pub/Sub-invoked private Substrate Cloud Build trigger ID, or null while disabled."
  value       = var.enabled ? google_cloudbuild_trigger.release[0].id : null
}

output "release_request_topic" {
  description = "IAM-protected private Substrate release-request topic, or null while disabled."
  value       = var.enabled ? google_pubsub_topic.release_request[0].id : null
}

output "artifact_repository_prefix" {
  description = "Exact private GAR prefix receiving promoted Substrate artifacts, or null while disabled."
  value       = var.enabled ? local.release_prefix : null
}

output "staging_repository_prefix" {
  description = "Exact private GAR prefix receiving disposable Substrate candidates, or null while disabled."
  value       = var.enabled ? local.staging_prefix : null
}

output "evidence_bucket_name" {
  description = "Existing retained evidence bucket shared with the kagent publisher, or null while disabled."
  value       = var.enabled ? var.evidence_bucket_name : null
}
