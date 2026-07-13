output "values" {
  description = "Map of logical name => plaintext latest secret value. Sensitive."
  value       = { for k, v in data.google_secret_manager_secret_version.this : k => v.secret_data }
  sensitive   = true
}
