output "connection_id" {
  description = "Fully-qualified Cloud Build 2nd-gen connection ID (the shared, out-of-band connection this repository is linked to)."
  value       = local.connection_id
}

output "repository_id" {
  description = "Fully-qualified Cloud Build 2nd-gen repository ID."
  value       = google_cloudbuildv2_repository.this.id
}

output "build_service_account_email" {
  description = "Email of the least-privilege image-build service account."
  value       = google_service_account.build.email
}

output "trigger_ids" {
  description = "Map of build name => Cloud Build trigger ID."
  value       = { for k, t in google_cloudbuild_trigger.this : k => t.id }
}

output "image_path" {
  description = "Full unified image path (no tag), e.g. europe-west3-docker.pkg.dev/PROJECT/docker/mattermost. The release resolves the pushed source tag and promotes one immutable digest dev -> prod."
  value       = local.image_repo_path
}
