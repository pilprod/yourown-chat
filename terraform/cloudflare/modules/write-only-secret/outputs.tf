output "secret_id" {
  description = "Short Secret Manager secret ID."
  value       = google_secret_manager_secret.this.secret_id
}

output "secret_version_id" {
  description = "Created Secret Manager version resource ID. The payload remains write-only."
  value       = google_secret_manager_secret_version.this.id
}
