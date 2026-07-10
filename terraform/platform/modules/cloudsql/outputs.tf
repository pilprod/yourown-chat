output "instance_name" {
  description = "Cloud SQL instance name."
  value       = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "Instance connection name (project:region:instance) for the Cloud SQL Auth Proxy."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip_address" {
  description = "Private IP of the instance."
  value       = google_sql_database_instance.this.private_ip_address
}

output "database_name" {
  description = "Application database name."
  value       = google_sql_database.app.name
}

output "user_name" {
  description = "Application database user name."
  value       = google_sql_user.app.name
}

output "password_secret_id" {
  description = "Secret Manager secret ID holding the DB user password."
  value       = google_secret_manager_secret.db_password.secret_id
}

output "connection_secret_id" {
  description = "Secret Manager secret ID holding the connection URI (null unless create_connection_secret = true)."
  value       = var.create_connection_secret ? google_secret_manager_secret.connection[0].secret_id : null
}

output "password_secret_version_id" {
  description = "Secret Manager secret version resource ID."
  value       = google_secret_manager_secret_version.db_password.id
}
