output "bucket_name" {
  description = "Name of the bucket."
  value       = google_storage_bucket.this.name
}

output "bucket_url" {
  description = "gs:// URL of the bucket."
  value       = google_storage_bucket.this.url
}

output "bucket_self_link" {
  description = "Self link of the bucket."
  value       = google_storage_bucket.this.self_link
}

output "filestore_service_account_email" {
  description = "Email of the dedicated filestore SA (null unless create_filestore_hmac = true)."
  value       = local.filestore_enabled ? google_service_account.filestore[0].email : null
}

output "filestore_access_key_secret_id" {
  description = "Secret Manager secret ID holding the S3-compatible access key ID (null unless create_filestore_hmac = true)."
  value       = local.filestore_enabled ? google_secret_manager_secret.filestore_access_key[0].secret_id : null
}

output "filestore_secret_key_secret_id" {
  description = "Secret Manager secret ID holding the S3-compatible secret key (null unless create_filestore_hmac = true)."
  value       = local.filestore_enabled ? google_secret_manager_secret.filestore_secret_key[0].secret_id : null
}
