# App-gcp stack outputs — the GCP delivery-layer surface (CI/CD, GitOps, operators).

# --- Continuous delivery ------------------------------------------------------
output "clouddeploy_pipeline_names" {
  type        = map(string)
  description = "Component => Cloud Deploy delivery pipeline name."
  value = {
    mattermost         = component.clouddeploy.delivery_pipeline_name
    mattermost-preview = component.clouddeploy_mattermost_preview.delivery_pipeline_name
    mcp                = component.clouddeploy_mcp.delivery_pipeline_name
    yourown-chat       = component.clouddeploy_server.delivery_pipeline_name
    agents-start       = component.clouddeploy_agents_start.delivery_pipeline_name
    agents-pause       = component.clouddeploy_agents_pause.delivery_pipeline_name
  }
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
  description = "Unified image path without tag, e.g. europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost. Cloud Build resolves the pushed source tag to one immutable digest and promotes that digest dev -> prod."
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
  description = "Cloud Build 2nd-gen repository ID linking the connection to the product assembly source repository (catalog role mattermost)."
  value       = component.mattermost_image.repository_id
}

output "web_source_repository_id" {
  type        = string
  description = "Cloud Build 2nd-gen repository ID used to mint short-lived credentials for the private web submodule."
  value       = component.mattermost_image.web_source_repository_id
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

output "application_source_trigger_ids" {
  type        = map(string)
  description = "Cloud Build CI and immutable-image triggers for the backend and agent source repositories (catalog roles backend, agents)."
  value       = component.deploy_release.application_source_trigger_ids
}

output "temporal_enabled" {
  type        = bool
  description = "Whether the explicit Terraform launch gate currently permits the Temporal component."
  value       = var.temporal_enabled
}

# --- Cluster bootstrap --------------------------------------------------------
output "mattermost_operator_chart_version" {
  type        = string
  description = "Installed mattermost-operator chart version."
  value       = component.cluster_bootstrap.mattermost_operator_chart_version
}

output "ingress_nginx_chart_version" {
  type        = string
  description = "Installed ingress-nginx chart version (null when the release is skipped)."
  value       = component.cluster_bootstrap.ingress_nginx_chart_version
}
