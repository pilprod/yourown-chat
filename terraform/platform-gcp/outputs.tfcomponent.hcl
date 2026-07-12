# Platform stack outputs. Two audiences:
#   1. Humans / CI (helm REPLACE-ME markers, kubectl annotations).
#   2. The LINKED downstream stacks: every value republished by a publish_output block
#      in platform.tfdeploy.hcl is declared here first (deployment outputs can
#      only reference stack outputs).

# --- GKE ---------------------------------------------------------------------
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

output "gke_cluster_id" {
  type        = string
  description = "Full GKE cluster resource ID (projects/<p>/locations/<l>/clusters/<n>). Consumed by the app-gcp stack's Cloud Deploy targets."
  value       = component.gke.cluster_id
}

# --- Storage -------------------------------------------------------------------
output "gcs_bucket_name" {
  type        = string
  description = "Application object-storage bucket."
  value       = component.storage.bucket_name
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

# --- Network -------------------------------------------------------------------
output "ingress_ip_address" {
  type        = string
  description = "Reserved static external IP for the public ingress (the Cloudflare 'white address'). Null when public_ingress_enabled = false. The cloudflare stack wires its apex A record to this value via upstream_input."
  value       = component.network.ingress_ip_address
}

# --- Cloud SQL -----------------------------------------------------------------
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

output "cloudsql_connection_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the Mattermost DB connection URI (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.connection_secret_id])
}

# --- Workload Identity -----------------------------------------------------------
output "workload_identity_emails" {
  type        = map(string)
  description = "Tenant => Google SA email to annotate the matching KSA (iam.gke.io/gcp-service-account)."
  value = {
    mattermost   = component.workload_identity_mattermost.email
    matterbridge = component.workload_identity_matterbridge.email
    dev          = component.workload_identity_dev.email
  }
}

output "workload_identity_members" {
  type        = map(string)
  description = "Tenant => IAM member string (serviceAccount:<email>). Consumed by the app-gcp stack as least-privilege secretAccessor grants."
  value = {
    mattermost   = component.workload_identity_mattermost.iam_member
    matterbridge = component.workload_identity_matterbridge.iam_member
    dev          = component.workload_identity_dev.iam_member
  }
}

# --- Encryption ----------------------------------------------------------------
output "cmek_key_id" {
  type        = string
  description = "Shared CMEK key resource ID (null when cmek_enabled = false), encrypting Cloud SQL + GCS + Secret Manager -- including the app-gcp stack's secrets and release-source bucket (via upstream_input)."
  value       = one([for k in component.kms : k.crypto_key_id])
}

# --- Container registry ----------------------------------------------------------
output "registry_repository_path" {
  type        = string
  description = "Unified Artifact Registry repository path: HOST/PROJECT/REPO (e.g. europe-west3-docker.pkg.dev/yourown-chat/docker)."
  value       = component.artifact_registry.repository_path
}

output "artifact_registry_location" {
  type        = string
  description = "Artifact Registry location. Consumed by the app-gcp stack's image CI."
  value       = component.artifact_registry.location
}

output "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry repository ID. Consumed by the app-gcp stack's image CI."
  value       = component.artifact_registry.repository_id
}
