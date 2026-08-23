output "service_account_email" {
  description = "Email of the least-privilege chart-publish build identity (repo-scoped writer on the unified registry)."
  value       = google_service_account.chart_publish.email
}

output "trigger_id" {
  description = "ID of the canonical-branch Cloud Build trigger that publishes platform chart versions."
  value       = google_cloudbuild_trigger.publish.id
}

output "chart_registry" {
  description = "OCI base reference that service wrappers pin platform charts from, e.g. oci://europe-west3-docker.pkg.dev/<project>/docker/charts."
  value       = "oci://${local.chart_registry_path}"
}
