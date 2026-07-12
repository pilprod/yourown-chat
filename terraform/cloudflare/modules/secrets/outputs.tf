output "secret_ids" {
  description = "Map of logical name => Secret Manager secret_id (short name)."
  value       = { for k, s in google_secret_manager_secret.this : k => s.secret_id }
}

output "secret_resource_ids" {
  description = "Map of logical name => fully-qualified secret resource ID."
  value       = { for k, s in google_secret_manager_secret.this : k => s.id }
}

output "secret_version_ids" {
  description = "Map of logical name => created version resource ID (only for generated/provided secrets)."
  value       = { for k, v in google_secret_manager_secret_version.this : k => v.id }
}
