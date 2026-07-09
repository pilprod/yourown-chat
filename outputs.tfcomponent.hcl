# Stack outputs — expose only what downstream consumers (CI/CD, GitOps, other
# stacks / future Infragraph) actually need.

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

output "artifact_registry_path" {
  type        = string
  description = "Image path prefix: HOST/PROJECT/REPO."
  value       = component.artifact_registry.repository_path
}

output "gcs_bucket_name" {
  type        = string
  description = "Application object-storage bucket."
  value       = component.storage.bucket_name
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

output "cloudbuild_service_account" {
  type        = string
  description = "Cloud Build service account email."
  value       = component.cloudbuild.service_account_email
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
