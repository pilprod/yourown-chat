# App-gcp stack outputs — the GCP delivery-layer surface (CI/CD, GitOps, operators).

# --- Continuous delivery ------------------------------------------------------
output "clouddeploy_pipeline_name" {
  type        = string
  description = "Cloud Deploy delivery pipeline name."
  value       = component.clouddeploy.delivery_pipeline_name
}

# --- Application secrets --------------------------------------------------------
output "app_secret_ids" {
  type        = map(string)
  description = "Logical name => Secret Manager secret ID for additional app secrets."
  value       = component.secrets.secret_ids
}

# --- Image-build CI ---------------------------------------------------------
output "image_path" {
  type        = string
  description = "Unified image path without tag, e.g. europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost. Reference this in BOTH Mattermost manifests with the single pushed tag (e.g. :v9.11.3-patched), promoted dev -> prod."
  value       = component.mattermost_image.image_path
}

output "trigger_ids" {
  type        = map(string)
  description = "Map of build name => Cloud Build trigger ID."
  value       = component.mattermost_image.trigger_ids
}

output "connection_id" {
  type        = string
  description = "Cloud Build 2nd-gen GitHub connection ID."
  value       = component.mattermost_image.connection_id
}

output "source_repository_id" {
  type        = string
  description = "Cloud Build 2nd-gen repository ID linking the connection to github.com/pilprod/mattermost."
  value       = component.mattermost_image.repository_id
}

output "build_service_account_email" {
  type        = string
  description = "Email of the least-privilege image-build service account (repo-scoped writer on the unified registry)."
  value       = component.mattermost_image.build_service_account_email
}

# --- Automated release cutting ----------------------------------------------
output "deploy_connection_id" {
  type        = string
  description = "Cloud Build 2nd-gen connection ID for the deploy repo (the release-cutting connection, separate from image CI)."
  value       = component.deploy_release.connection_id
}

output "release_trigger_id" {
  type        = string
  description = "ID of the tag-triggered Cloud Build trigger that cuts a Cloud Deploy release on a semver tag."
  value       = component.deploy_release.trigger_id
}

output "release_service_account_email" {
  type        = string
  description = "Email of the least-privilege releaser SA (clouddeploy.releaser on the pipeline only; actAs the execution SA)."
  value       = component.deploy_release.releaser_service_account_email
}

output "release_source_bucket" {
  type        = string
  description = "Private staging bucket the release source tarballs are uploaded to."
  value       = component.deploy_release.source_bucket_name
}
