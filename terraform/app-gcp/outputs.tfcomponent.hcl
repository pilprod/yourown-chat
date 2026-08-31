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
    kagent-substrate   = component.clouddeploy_kagent_substrate.delivery_pipeline_name
  }
}

output "kagent_substrate_bootstrap_ready" {
  type        = bool
  description = "Whether the pre-sync Secret Manager containers, namespace, exact contract, RBAC and immutable Substrate CRDs are ready."
  value = (
    var.kagent_substrate_delivery.bootstrap_enabled &&
    component.substrate_prerequisites.bootstrap_ready
  )
}

output "kagent_substrate_delivery_ready" {
  type        = bool
  description = "Whether immutable application pins, Terraform CRD ownership and native Substrate secret synchronization are all enabled."
  value = (
    var.kagent_substrate_delivery.release_enabled &&
    var.kagent_substrate_delivery.native_secret_sync_ready &&
    local.kagent_substrate_crd_prerequisites_ready &&
    component.substrate_prerequisites.release_ready &&
    var.agentgateway_platform.enabled &&
    var.agentgateway_public_ip_address != null
  )
}

output "kagent_substrate_production_eligible" {
  type        = bool
  description = "Whether the admitted immutable kagent artifact is eligible for dev verification followed by approval-gated production promotion."
  value = (
    var.kagent_substrate_delivery.release_enabled &&
    var.kagent_substrate_delivery.production_eligible
  )
}

output "external_broker_smoke_required" {
  type        = bool
  description = "True until an external Agent Host TLS+gRPC smoke has been explicitly attested; the production PREDEPLOY rollout gate fails closed while true."
  value       = !component.substrate_prerequisites.external_broker_smoke_ready
}

output "kagent_local_agent_ready" {
  type        = bool
  description = "True only after the deploy rail is ready and a real external Broker smoke has been separately attested."
  value = (
    var.kagent_substrate_delivery.release_enabled &&
    var.kagent_substrate_delivery.native_secret_sync_ready &&
    local.kagent_substrate_crd_prerequisites_ready &&
    component.substrate_prerequisites.release_ready &&
    var.agentgateway_platform.enabled &&
    var.agentgateway_public_ip_address != null &&
    component.substrate_prerequisites.external_broker_smoke_ready
  )
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
  description = "Cloud Build CI and immutable-image triggers for the backend source repository."
  value       = component.deploy_release.application_source_trigger_ids
}

output "kagent_preview_publisher" {
  type = object({
    enabled                    = bool
    service_account_email      = string
    evidence_bucket_name       = string
    source_uri                 = string
    trigger_id                 = string
    release_request_topic      = string
    artifact_repository_prefix = string
    ghcr_secret_id             = string
  })
  description = "Non-sensitive coordinates of the dedicated kagent fork preview publication infrastructure."
  value = {
    enabled                    = component.kagent_preview_publisher.enabled
    service_account_email      = component.kagent_preview_publisher.service_account_email
    evidence_bucket_name       = component.kagent_preview_publisher.evidence_bucket_name
    source_uri                 = component.kagent_preview_publisher.source_uri
    trigger_id                 = component.kagent_preview_publisher.trigger_id
    release_request_topic      = component.kagent_preview_publisher.release_request_topic
    artifact_repository_prefix = component.kagent_preview_publisher.artifact_repository_prefix
    ghcr_secret_id             = component.kagent_preview_publisher.ghcr_secret_id
  }
}

output "temporal_enabled" {
  type        = bool
  description = "Whether the explicit Terraform launch gate currently permits the Temporal component."
  value       = var.temporal_enabled
}

output "vendor_chart_bundle_releases" {
  type = map(object({
    bundle_key               = string
    provisioned              = bool
    application_requested    = bool
    database_bindings_ready  = bool
    application_materialized = bool
    candidate_tag            = string
    product_commit           = string
    source_commit            = string
    namespace                = string
    crd_release_name         = string
    crd_status               = string
    application_release_name = string
    application_status       = string
  }))
  description = "Applied generic vendor bundle identities and readiness; no secret values are exposed."
  value = {
    for key, bundle in component.vendor_chart_bundle : key => bundle.release
  }
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
