output "connection_id" {
  description = "Fully-qualified Cloud Build 2nd-gen connection ID."
  value       = google_cloudbuildv2_connection.github.id
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
  description = "Full unified image path (no tag), e.g. europe-west3-docker.pkg.dev/PROJECT/docker/mattermost. Reference this in the Mattermost manifests with the pushed tag (single tag, e.g. :v9.11.3-patched, promoted dev -> prod)."
  value       = local.image_repo_path
}

output "pat_secret_grant_id" {
  description = "ID of the Cloud Build service agent's secretAccessor grant on the GitHub PAT. A project singleton owned here — pass it to any other component (e.g. deploy-release) that opens its own 2nd-gen connection, so that component orders AFTER this grant instead of re-creating it (which would conflict)."
  value       = google_secret_manager_secret_iam_member.agent_reads_pat.id
}
