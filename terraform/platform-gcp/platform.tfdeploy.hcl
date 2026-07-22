# PLATFORM deployment `eu`: the stateful foundation (APIs, network + ingress
# IP, CMEK, one zonal GKE cluster, Cloud SQL, storage, registry, Workload
# Identity SAs). Downstream cloudflare/app-gcp stacks consume the
# publish_output contract below. Keyless auth: HCP Dynamic Provider
# Credentials -> WIF. NOTE: varsets carry SECRETS ONLY -- store values are
# ephemeral in Stacks, so operational toggles must be committed literals here.

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project        = "yourown-chat"
  gcp_project_number = "1086706391144"
  gcp_region         = "europe-west3"
  gcp_zone           = "europe-west3-b"

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

    project_id     = local.gcp_project
    project_number = local.gcp_project_number
    environment    = "prod"
    region         = local.gcp_region
    zone           = local.gcp_zone

    # ONE zonal cluster (GKE free tier), two pools: prod tainted
    # dedicated=prod; dev untainted and on-demand because it hosts
    # kube-system/CoreDNS, which must not be preempted.
    gke_regional            = false
    gke_deletion_protection = true
    gke_node_pools = {
      prod = {
        machine_type = "e2-standard-2"
        spot         = false
        min_count    = 1
        max_count    = 2
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "prod" }
        taints       = [{ key = "dedicated", value = "prod", effect = "NO_SCHEDULE" }]
      }
      dev = {
        machine_type = "e2-medium"
        spot         = false
        min_count    = 1
        max_count    = 3
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "dev" }
        taints       = []
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

    public_ingress_enabled = true

    # One shared HSM CMEK key for Cloud SQL + GCS + Secret Manager (~$1/mo).
    cmek_enabled         = true
    kms_protection_level = "HSM"
    # Ring/key survive deletion in GCP -- adopt instead of 409-ing on create.
    kms_adopt_existing = true

    storage_force_destroy = false

    # Registry is public -> no CMEK.
    artifact_registry_kms_key_name           = null
    artifact_registry_vulnerability_scanning = true

    extra_labels = { cost-center = "platform" }
  }
}

# Linked-stack contract: last-APPLIED values consumed as
# upstream_input.platform.<name>; an apply here auto-triggers downstream plans.
publish_output "ingress_ip_address" {
  description = "Reserved static ingress IP the Cloudflare apex A record points at."
  value       = deployment.eu.ingress_ip_address
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

publish_output "workload_identity_members" {
  description = "Tenant => IAM member string for least-privilege secretAccessor grants in the app-gcp stack."
  value       = deployment.eu.workload_identity_members
}

publish_output "gcs_bucket_name" {
  description = "Mattermost object-storage bucket, rendered into the operator CR via Cloud Deploy deploy parameters."
  value       = deployment.eu.gcs_bucket_name
}

publish_output "workload_identity_emails" {
  description = "Tenant => GSA email, rendered into the KSA annotations via Cloud Deploy deploy parameters."
  value       = deployment.eu.workload_identity_emails
}
