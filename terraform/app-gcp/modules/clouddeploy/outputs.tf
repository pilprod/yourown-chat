output "delivery_pipeline_name" {
  description = "Cloud Deploy delivery pipeline name."
  value       = google_clouddeploy_delivery_pipeline.this.name
}

output "delivery_pipeline_id" {
  description = "Fully-qualified delivery pipeline resource ID."
  value       = google_clouddeploy_delivery_pipeline.this.id
}

output "target_names" {
  description = "Map of stage name => Cloud Deploy target name."
  value       = { for k, t in google_clouddeploy_target.stage : k => t.name }
}

output "execution_service_account_email" {
  description = "Email of the Cloud Deploy execution SA."
  value       = google_service_account.exec.email
}

output "cleanup_service_account_email" {
  description = "Email of the dedicated PREDEPLOY cleanup SA (null when the pipeline has no predeploy actions)."
  value       = one(google_service_account.cleanup[*].email)
}
