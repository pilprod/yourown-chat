output "service_account_email" {
  description = "Email of the Cloud Build service account."
  value       = google_service_account.build.email
}

output "service_account_id" {
  description = "Fully-qualified Cloud Build service account resource ID."
  value       = google_service_account.build.id
}
