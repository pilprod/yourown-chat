output "secret_id" {
  description = "Non-secret Secret Manager ID containing the temporary first-user password."
  value       = google_secret_manager_secret.this.secret_id
}
