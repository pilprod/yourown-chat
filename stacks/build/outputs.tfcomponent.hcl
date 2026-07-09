# Build-stack outputs. Expose only what downstream consumers need: the image
# paths to reference in the Mattermost manifests, and IDs for troubleshooting.

output "image_paths" {
  type        = map(string)
  description = "Map of build name (prod/dev) => full image path without tag, e.g. europe-west3-docker.pkg.dev/yourown-chat/ycs-prod-containers/mattermost. Reference these in the Mattermost values with the pushed tag (e.g. :v9.11.3-patched)."
  value       = component.mattermost_image.image_paths
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

output "repository_id" {
  type        = string
  description = "Cloud Build 2nd-gen repository ID."
  value       = component.mattermost_image.repository_id
}

output "build_service_account_email" {
  type        = string
  description = "Email of the least-privilege image-build service account."
  value       = component.mattermost_image.build_service_account_email
}
