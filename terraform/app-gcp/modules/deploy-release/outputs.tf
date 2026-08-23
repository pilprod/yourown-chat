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

output "rtcd_image_trigger_id" {
  description = "ID of the RTCD source-tag image build trigger."
  value       = google_cloudbuild_trigger.rtcd_image.id
}

output "source_bucket_name" {
  description = "Name of the private source-staging bucket the release tarballs are uploaded to."
  value       = google_storage_bucket.source.name
}

output "application_source_repository_ids" {
  description = "Cloud Build repository links for the independent server and agent sources."
  value       = { for name, repository in google_cloudbuildv2_repository.source : name => repository.id }
}

output "application_source_trigger_ids" {
  description = "Branch and immutable-tag build triggers for the server and agent sources."
  value       = { for name, trigger in google_cloudbuild_trigger.source_image : name => trigger.id }
}

output "chart_publisher_service_account_email" {
  description = "Email of the platform chart publisher identity, or null when chart publication is disabled."
  value       = local.chart_publication ? google_service_account.chart_publisher[0].email : null
}

output "chart_publish_trigger_id" {
  description = "ID of the platform-charts publication trigger, or null when chart publication is disabled."
  value       = local.chart_publication ? google_cloudbuild_trigger.chart_publish[0].id : null
}
