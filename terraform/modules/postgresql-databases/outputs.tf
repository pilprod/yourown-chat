output "database_names" { value = sort([for database in google_sql_database.this : database.name]) }
output "user_name" { value = google_sql_user.this.name }
output "password_secret_id" { value = google_secret_manager_secret.password.secret_id }
output "password" {
  value     = random_password.this.result
  sensitive = true
}
