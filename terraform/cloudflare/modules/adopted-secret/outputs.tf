output "secret_id" {
  description = "Short Secret Manager secret ID."
  value       = google_secret_manager_secret.this.secret_id
}
