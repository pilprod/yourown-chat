# Build-stack outputs. Expose only what downstream consumers need: the unified
# image path to reference in the Mattermost manifests, plus IDs for troubleshooting.

output "image_path" {
  type        = string
  description = "Unified image path without tag, e.g. europe-west3-docker.pkg.dev/yourown-chat/ycs-containers/mattermost. Reference this in BOTH Mattermost manifests with the pushed tag (prod :v9.11.3-patched, dev :v9.11.3-patched-dev)."
  value       = component.mattermost_image.image_path
}

output "registry_repository_path" {
  type        = string
  description = "Unified Artifact Registry repository path: HOST/PROJECT/REPO (e.g. europe-west3-docker.pkg.dev/yourown-chat/ycs-containers)."
  value       = component.artifact_registry.repository_path
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
