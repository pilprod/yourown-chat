output "enabled" {
  description = "Whether the publication rail is materialized (a chart repository was supplied)."
  value       = local.enabled
}

output "service_account_email" {
  description = "Email of the least-privilege chart-publish build identity, or null while the rail is disabled."
  value       = local.enabled ? google_service_account.chart_publish[0].email : null
}

output "trigger_id" {
  description = "ID of the canonical-branch Cloud Build trigger that publishes platform chart versions, or null while the rail is disabled."
  value       = local.enabled ? google_cloudbuild_trigger.publish[0].id : null
}

output "chart_registry" {
  description = "OCI base reference that service wrappers pin platform charts from, e.g. oci://europe-west3-docker.pkg.dev/<project>/<helm-repository>, or null while the rail is disabled."
  value       = local.enabled ? "oci://${local.chart_registry_path}" : null
}

output "evidence_bucket_name" {
  description = "Durable, versioned bucket holding one evidence object per published chart version, or null while the rail is disabled."
  value       = local.enabled ? google_storage_bucket.evidence[0].name : null
}
