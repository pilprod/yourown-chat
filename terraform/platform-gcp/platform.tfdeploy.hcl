# PLATFORM deployment `eu`: the stateful foundation (APIs, network + ingress
# IP, CMEK, one zonal GKE cluster, Cloud SQL, storage, registry, Workload
# Identity SAs). Downstream cloudflare/app-gcp stacks consume the
# publish_output contract below. Keyless auth: HCP Dynamic Provider
# Credentials -> WIF. NOTE: varsets carry SECRETS ONLY -- store values are
# ephemeral in Stacks, so operational toggles must be committed literals here.

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project            = "yourown-chat"
  gcp_project_number     = "1086706391144"
  gcp_billing_account_id = "01B729-537989-CCA4BB"
  gcp_region             = "europe-west3"
  gcp_zone               = "europe-west3-b"

  # Empty list = control-plane endpoint reachable from anywhere (credentials
  # still required). Restricting CIDRs would also block Cloud Deploy's
  # Google-owned egress -- lock down only once a private CD path exists.
  master_authorized_networks = []
}

identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

deployment "eu" {
  inputs = {
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id         = local.gcp_project
    project_number     = local.gcp_project_number
    billing_account_id = local.gcp_billing_account_id
    environment        = "prod"
    region             = local.gcp_region
    zone               = local.gcp_zone

    # ONE zonal cluster (GKE free tier) with an autoscaling general-purpose
    # pool. Standalone RTCD shares this pool; its requests and production
    # PriorityClass preserve media capacity without paying for an idle node.
    # Kubernetes PriorityClass + requests/quotas protect prod capacity; dev
    # workloads are preemptible and scaled down after release verification.
    gke_regional            = false
    gke_deletion_protection = true
    gke_node_pools = {
      # GKE cannot add CMEK to existing boot disks. The first apply with
      # cmek_boot_disk=true intentionally deletes and recreates this pool with
      # the same name, causing a temporary workload outage but avoiding a
      # second migration pool.
      general = {
        machine_type   = "e2-standard-2"
        spot           = false
        min_count      = 1
        max_count      = 3
        disk_size_gb   = 30
        disk_type      = "pd-standard"
        cmek_boot_disk = true
        labels = {
          pool = "general"
        }
        taints = []
      }
    }

    master_authorized_networks = local.master_authorized_networks

    # Prod-only managed Postgres (dev runs an in-cluster StatefulSet).
    cloudsql_enabled               = true
    cloudsql_tier                  = "db-f1-micro"
    cloudsql_availability_type     = "ZONAL"
    cloudsql_disk_size_gb          = 20
    cloudsql_pitr_enabled          = true
    cloudsql_backup_retained_count = 7
    cloudsql_txlog_retention_days  = 7
    cloudsql_deletion_protection   = true
    # Rotation trigger: change the value (a date), apply, then restart the
    # consumers so they pick up the new connection secret.
    cloudsql_password_rotation = "2026-07-12"
    # Native identity is part of the server platform; no external identity
    # runtime is provisioned for the pilot.
    yourown_chat_server_enabled              = true
    yourown_chat_identity_password_rotation = "1"

    # One-release cutover guard: preserve the existing runtime and database
    # until the native server release and bootstrap migration are verified.
    # No application ingress or client contract points at this runtime.
    keycloak_enabled           = true
    keycloak_version           = "26.7.1"
    keycloak_password_rotation = "1"
    keycloak_public_url        = "https://auth.yourown.chat"

    # Temporal is a platform-gcp service. Keep the launch gate closed until the
    # prerequisite MCP image has passed production verification.
    temporal_enabled             = false
    temporal_chart_version       = "1.2.0"
    temporal_password_rotation   = "1"
    agent_results_retention_days = 30

    public_ingress_enabled   = true
    mattermost_calls_enabled = true

    # One shared HSM CMEK key for Cloud SQL, GCS, Secret Manager, GKE etcd,
    # sensitive PVCs and the replacement GKE node-pool boot disks (~$1/mo).
    cmek_enabled         = true
    kms_protection_level = "HSM"
    # Ring/key survive deletion in GCP -- adopt instead of 409-ing on create.
    kms_adopt_existing = true

    storage_force_destroy = false

    # Registry is public -> no CMEK.
    artifact_registry_kms_key_name = null
    # Paid per image digest. Keep the repository gate off during routine
    # builds; enable it only for a bounded build window through the guarded
    # Google Cloud MCP security_set_scanning tool, then disable it again.
    artifact_registry_vulnerability_scanning = false

    extra_labels = { cost-center = "platform" }
  }
}

# Linked-stack contract: last-APPLIED values consumed as
# upstream_input.platform.<name>; an apply here auto-triggers downstream plans.
publish_output "ingress_ip_address" {
  description = "Reserved static ingress IP the Cloudflare apex A record points at."
  value       = deployment.eu.ingress_ip_address
}

publish_output "calls_ip_address" {
  description = "Stable public address for direct Mattermost RTCD TCP/UDP media traffic."
  value       = deployment.eu.calls_ip_address
}

publish_output "nat_egress_ip_address" {
  description = "Reserved Cloud NAT egress IP to allowlist in Google Workspace SMTP Relay."
  value       = deployment.eu.nat_egress_ip_address
}

publish_output "gke_cluster_id" {
  description = "Full GKE cluster resource ID for the Cloud Deploy targets."
  value       = deployment.eu.gke_cluster_id
}

publish_output "artifact_registry_location" {
  description = "Artifact Registry location for the image CI."
  value       = deployment.eu.artifact_registry_location
}

publish_output "artifact_registry_repository_id" {
  description = "Artifact Registry repository ID for the image CI."
  value       = deployment.eu.artifact_registry_repository_id
}

publish_output "cmek_key_id" {
  description = "Shared CMEK key (null when cmek_enabled = false) for the app-gcp stack's secrets + release-source bucket."
  value       = deployment.eu.cmek_key_id
}

publish_output "identity_bootstrap_user_password_secret_id" {
  description = "Secret Manager ID used once to create the first native platform user."
  value       = deployment.eu.identity_bootstrap_user_password_secret_id
}

publish_output "workload_identity_members" {
  description = "Tenant => IAM member string for least-privilege secretAccessor grants in the app-gcp stack."
  value       = deployment.eu.workload_identity_members
}

publish_output "gcs_bucket_name" {
  description = "Mattermost object-storage bucket, rendered into the operator CR via Cloud Deploy deploy parameters."
  value       = deployment.eu.gcs_bucket_name
}

publish_output "cloudsql_private_ip" {
  description = "Exact private Cloud SQL address consumed by the production Mattermost NetworkPolicy."
  value       = deployment.eu.cloudsql_private_ip
}

publish_output "cluster_dns_ip" {
  description = "Exact kube-dns Service ClusterIP consumed by restricted application network policies."
  value       = deployment.eu.cluster_dns_ip
}

publish_output "cloudsql_instance_name" {
  description = "Cloud SQL instance name consumed by database-owning application components."
  value       = deployment.eu.cloudsql_instance_name
}

publish_output "yourown_chat_identity_connection_secret_id" {
  description = "Secret Manager ID for the identity database migration connection URI."
  value       = deployment.eu.yourown_chat_identity_connection_secret_id
}

publish_output "yourown_chat_identity_runtime_connection_secret_id" {
  description = "Secret Manager ID for the least-privilege identity runtime database connection URI."
  value       = deployment.eu.yourown_chat_identity_runtime_connection_secret_id
}

publish_output "workload_identity_emails" {
  description = "Tenant => GSA email, rendered into the KSA annotations via Cloud Deploy deploy parameters."
  value       = deployment.eu.workload_identity_emails
}

publish_output "temporal_enabled" {
  description = "Platform-owned Temporal launch state consumed by app-gcp delivery gates."
  value       = deployment.eu.temporal_enabled
}

publish_output "yourown_chat_server_enabled" {
  description = "Platform-owned launch state for the independent YourOwn.Chat server plane."
  value       = deployment.eu.yourown_chat_server_enabled
}

publish_output "keycloak_enabled" {
  description = "Temporary cutover guard state; no application consumer uses it."
  value       = deployment.eu.keycloak_enabled
}

publish_output "keycloak_issuer" {
  description = "Legacy issuer retained during the one-release cutover only."
  value       = deployment.eu.keycloak_issuer
}

publish_output "temporal_results_bucket_name" {
  description = "Platform-owned agent result bucket consumed by application delivery parameters."
  value       = deployment.eu.temporal_results_bucket_name
}
