output "connection_id" {
  description = "Fully-qualified Cloud Build 2nd-gen connection ID for the deploy repository (the shared, out-of-band connection it is linked to)."
  value       = local.connection_id
}

output "repository_id" {
  description = "Fully-qualified Cloud Build 2nd-gen repository ID for the deploy repository."
  value       = google_cloudbuildv2_repository.this.id
}

output "releaser_service_account_email" {
  description = "Email of the least-privilege release-cutter service account."
  value       = google_service_account.releaser.email
}

output "trigger_id" {
  description = "ID of the tag-triggered Cloud Build trigger that cuts Cloud Deploy releases."
  value       = google_cloudbuild_trigger.release.id
}

output "source_bucket_name" {
  description = "Name of the private source-staging bucket the release tarballs are uploaded to."
  value       = google_storage_bucket.source.name
}
