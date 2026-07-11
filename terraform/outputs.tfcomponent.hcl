# Stack outputs — expose only what downstream consumers (CI/CD, GitOps,
# operators, future Infragraph) actually need. Cloudflare outputs are gated with
# one([...]) because the cloudflare component only exists when
# public_ingress_enabled = true.

# --- GCP platform -----------------------------------------------------------
output "gke_cluster_name" {
  type        = string
  description = "GKE cluster name."
  value       = component.gke.cluster_name
}

output "gke_location" {
  type        = string
  description = "GKE cluster location (zone or region)."
  value       = component.gke.location
}

output "gcs_bucket_name" {
  type        = string
  description = "Application object-storage bucket."
  value       = component.storage.bucket_name
}

output "ingress_ip_address" {
  type        = string
  description = "Reserved static external IP for the public ingress (the Cloudflare 'white address'). Null when public_ingress_enabled = false. The Cloudflare apex A record is wired to this value live."
  value       = component.network.ingress_ip_address
}

output "cloudsql_connection_name" {
  type        = string
  description = "Cloud SQL connection name for the Auth Proxy (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.connection_name])
}

output "cloudsql_password_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the DB password (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.password_secret_id])
}

output "cloudsql_private_ip" {
  type        = string
  description = "Private IP of the Cloud SQL instance (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.private_ip_address])
  sensitive   = true
}

output "clouddeploy_pipeline_name" {
  type        = string
  description = "Cloud Deploy delivery pipeline name."
  value       = component.clouddeploy.delivery_pipeline_name
}

output "cloudsql_connection_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the Mattermost DB connection URI (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.connection_secret_id])
}

output "filestore_access_key_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the GCS filestore S3 access key."
  value       = component.storage.filestore_access_key_secret_id
}

output "filestore_secret_key_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the GCS filestore S3 secret key."
  value       = component.storage.filestore_secret_key_secret_id
}

output "app_secret_ids" {
  type        = map(string)
  description = "Logical name => Secret Manager secret ID for additional app secrets."
  value       = component.secrets.secret_ids
}

output "workload_identity_emails" {
  type        = map(string)
  description = "Tenant => Google SA email to annotate the matching KSA (iam.gke.io/gcp-service-account)."
  value = {
    mattermost   = component.workload_identity_mattermost.email
    matterbridge = component.workload_identity_matterbridge.email
    dev          = component.workload_identity_dev.email
  }
}

output "cmek_key_id" {
  type        = string
  description = "Shared CMEK key resource ID (null when cmek_enabled = false), encrypting Cloud SQL + GCS + Secret Manager."
  value       = one([for k in component.kms : k.crypto_key_id])
}

# --- Image-build CI ---------------------------------------------------------
output "image_path" {
  type        = string
  description = "Unified image path without tag, e.g. europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost. Reference this in BOTH Mattermost manifests with the single pushed tag (e.g. :v9.11.3-patched), promoted dev -> prod."
  value       = component.mattermost_image.image_path
}

output "registry_repository_path" {
  type        = string
  description = "Unified Artifact Registry repository path: HOST/PROJECT/REPO (e.g. europe-west3-docker.pkg.dev/yourown-chat/docker)."
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

# --- Cloudflare edge (null when public_ingress_enabled = false) -------------
output "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for the managed domain."
  value       = one([for c in component.cloudflare : c.zone_id])
}

output "cloudflare_record_hostname" {
  type        = string
  description = "Fully-qualified hostname of the proxied apex A record."
  value       = one([for c in component.cloudflare : c.record_hostname])
}

output "cloudflare_origin_ip" {
  type        = string
  description = "IPv4 the proxied apex A record points at (echoes the platform ingress IP)."
  value       = one([for c in component.cloudflare : c.origin_ip])
}

output "cloudflare_dnssec" {
  type = object({
    status      = string
    ds          = string
    digest      = string
    key_tag     = string
    algorithm   = string
    digest_type = string
  })
  description = "DNSSEC DS material to publish at the registrar (null when dnssec disabled or no public ingress)."
  value       = one([for c in component.cloudflare : c.dnssec])
}
