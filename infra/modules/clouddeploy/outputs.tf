output "delivery_pipeline_name" {
  description = "Cloud Deploy delivery pipeline name."
  value       = google_clouddeploy_delivery_pipeline.this.name
}

output "delivery_pipeline_id" {
  description = "Fully-qualified delivery pipeline resource ID."
  value       = google_clouddeploy_delivery_pipeline.this.id
}

output "target_name" {
  description = "Cloud Deploy target name."
  value       = google_clouddeploy_target.gke.name
}

output "execution_service_account_email" {
  description = "Email of the Cloud Deploy execution SA."
  value       = google_service_account.exec.email
}
