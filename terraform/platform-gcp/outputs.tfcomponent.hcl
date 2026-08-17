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

output "calls_ip_address" {
  type        = string
  description = "Reserved external IP advertised by the Mattermost RTCD media service."
  value       = component.network.calls_ip_address
}

output "nat_egress_ip_address" {
  type        = string
  description = "Reserved static Cloud NAT egress IP. Allowlist this address in Google Workspace SMTP Relay."
  value       = component.network.nat_egress_ip_address
}

# --- Cloud SQL -----------------------------------------------------------------
output "cloudsql_connection_name" {
  type        = string
  description = "Cloud SQL instance connection name (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.connection_name])
}

output "cloudsql_instance_name" {
  type        = string
  description = "Cloud SQL instance name used to add logical pilot databases."
  value       = one([for database in component.cloudsql : database.instance_name])
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
}

output "cluster_dns_ip" {
  type        = string
  description = "Exact kube-dns Service ClusterIP used by Dataplane V2 network policies."
  value       = cidrhost(component.network.services_cidr, 10)
}

output "cloudsql_connection_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the Mattermost DB connection URI (null when Cloud SQL is disabled)."
  value       = one([for c in component.cloudsql : c.connection_secret_id])
}

output "yourown_chat_identity_connection_secret_id" {
  type        = string
  description = "Ready-to-use identity database URI secret ID, or null only when shared Cloud SQL is disabled."
  value       = try(one([for c in component.cloudsql : c.additional_connection_secret_ids["yourown_chat_identity"]]), null)
}

output "yourown_chat_identity_runtime_connection_secret_id" {
  type        = string
  description = "Least-privilege runtime identity database URI secret ID."
  value       = try(one([for c in component.cloudsql : c.additional_connection_secret_ids["yourown_chat_identity_runtime"]]), null)
}

# --- Cloud Billing -------------------------------------------------------------
output "billing_export_dataset_id" {
  type        = string
  description = "BigQuery dataset selected for Detailed Cloud Billing export."
  value       = component.billing_export.dataset_id
}

output "billing_detailed_export_table" {
  type        = string
  description = "Expected detailed usage table created by Cloud Billing after export is enabled."
  value       = component.billing_export.detailed_export_table
}

output "billing_monthly_budget_name" {
  type        = string
  description = "Protected USD 100 monthly budget with actual and forecast thresholds."
  value       = component.billing_budget.name
}

# --- Workload Identity -----------------------------------------------------------
output "workload_identity_emails" {
  type        = map(string)
  description = "Tenant => Google SA email to annotate the matching KSA (iam.gke.io/gcp-service-account)."
  value = {
    mattermost           = component.workload_identity_mattermost.email
    matterbridge         = component.workload_identity_matterbridge.email
    dev                  = component.workload_identity_dev.email
    mcp                  = component.workload_identity_mcp.email
    mcp-dev              = component.workload_identity_mcp_dev.email
    mcp-terraform-stacks = component.workload_identity_mcp_terraform_stacks.email
    mcp-tunnel           = component.workload_identity_mcp_tunnel.email
    agents               = component.workload_identity_agents.email
    backend-control-api   = component.workload_identity_backend_control_api.email
    identity-api          = component.workload_identity_identity_api.email
    identity-admin        = component.workload_identity_identity_admin.email
    identity-migrate      = component.workload_identity_identity_migrate.email
    agents-workflow      = component.workload_identity_agent_workflow.email
    agents-activity      = component.workload_identity_agents.email
  }
}

output "workload_identity_members" {
  type        = map(string)
  description = "Tenant => IAM member string (serviceAccount:<email>). Consumed by the app-gcp stack as least-privilege secretAccessor grants."
  value = {
    mattermost           = component.workload_identity_mattermost.iam_member
    matterbridge         = component.workload_identity_matterbridge.iam_member
    dev                  = component.workload_identity_dev.iam_member
    mcp                  = component.workload_identity_mcp.iam_member
    mcp-dev              = component.workload_identity_mcp_dev.iam_member
    mcp-terraform-stacks = component.workload_identity_mcp_terraform_stacks.iam_member
    mcp-tunnel           = component.workload_identity_mcp_tunnel.iam_member
    agents               = component.workload_identity_agents.iam_member
    backend-control-api   = component.workload_identity_backend_control_api.iam_member
    identity-api          = component.workload_identity_identity_api.iam_member
    identity-admin        = component.workload_identity_identity_admin.iam_member
    identity-migrate      = component.workload_identity_identity_migrate.iam_member
    agents-workflow      = component.workload_identity_agent_workflow.iam_member
    agents-activity      = component.workload_identity_agents.iam_member
  }
}

# --- Encryption ----------------------------------------------------------------
output "cmek_key_id" {
  type        = string
  description = "Shared CMEK key resource ID (null when cmek_enabled = false), protecting Cloud SQL, GCS, Secret Manager, GKE etcd, sensitive PVCs and opted-in node boot disks."
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

# --- Temporal platform service ----------------------------------------------
output "temporal_enabled" {
  type        = bool
  description = "Whether platform-gcp has enabled the official Temporal service."
  value       = var.temporal_enabled
}

output "yourown_chat_server_enabled" {
  type        = bool
  description = "Whether the independent YourOwn.Chat server plane foundation is enabled."
  value       = var.yourown_chat_server_enabled
}

output "keycloak_enabled" {
  type        = bool
  description = "Whether platform-gcp owns an active Keycloak identity runtime."
  value       = var.keycloak_enabled
}

output "keycloak_issuer" {
  type        = string
  description = "Canonical OpenID Connect issuer for the YourOwn.Chat realm."
  value       = component.keycloak.issuer
}

output "keycloak_internal_url" {
  type        = string
  description = "Cluster-only Keycloak base URL for trusted backend calls."
  value       = component.keycloak.internal_url
}

output "temporal_results_bucket_name" {
  type        = string
  description = "Private agent result bucket created by platform-gcp when Temporal is enabled."
  value       = try(component.storage.additional_bucket_names["agent-results"], null)
}

output "temporal_release_name" {
  type        = string
  description = "Installed official Temporal Helm release name, or null while the launch gate is closed."
  value       = component.temporal.release_name
}
