# ---------------------------------------------------------------------------
# Deployments = environments. Two Terraform Stacks deployments, each a fully
# isolated environment with its OWN GKE cluster, VPC and data plane, all living
# in the single GCP project `yourown-chat`. Every resource is prefixed per
# environment (ycs-dev-*, ycs-prod-*) so the two deployments never collide
# inside the shared project.
#
# COST TRADEOFF (accepted): GKE's free tier waives the management fee for only
# ONE zonal cluster per billing account. The second cluster adds ~$74/mo, so
# running dev + prod is ~$140-150/mo (vs ~$90 for the earlier single-cluster,
# two-node-pool topology). This buys physical dev/prod isolation and an
# independent lifecycle per environment. dev is minimized to claw cost back:
# a single Spot node and in-cluster Postgres (no managed Cloud SQL).
#
# AUTH: keyless HCP Terraform Dynamic Provider Credentials -> GCP Workload
# Identity Federation (Stacks GA identity_token block; no TFC_GCP_* env vars,
# no static keys). HCP mints the OIDC JWT below; its `aud` MUST be one of the
# WIF provider's allowed-audiences. The google provider then exchanges it at
# STS (external_credentials.audience = the //iam.googleapis.com/... provider
# resource name) and impersonates the least-privilege apply SA. Nothing secret
# is committed. Bootstrap: docs/BOOTSTRAP.md + google_cloud_init.md.
# ---------------------------------------------------------------------------

locals {
  # --- Keyless auth wiring (project `yourown-chat`, shared by all deployments)
  # STS token-exchange audience = full WIF provider resource name (leading //).
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  # Least-privilege SA impersonated after the exchange (never Owner/Editor).
  gcp_apply_sa = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project = "yourown-chat"
  gcp_region  = "europe-west3" # Frankfurt, Germany
  gcp_zone    = "europe-west3-b"

  # CIDRs allowed to reach the GKE control-plane endpoint. The endpoint is public
  # but node-private (enable_private_endpoint = false); an EMPTY list omits the
  # network restriction, so the API stays reachable from anywhere yet still
  # requires valid GCP/Kubernetes credentials -- and Cloud Deploy can reach it.
  # Restricting to specific CIDRs would also block Cloud Deploy's Google-owned
  # egress, so lock down only once a Connect Gateway / private CD path exists:
  #   master_authorized_networks = [{ cidr_block = "203.0.113.10/32", display_name = "office" }]
  master_authorized_networks = []
}

# HCP mints this OIDC JWT once per run. Its `aud` claim must match the WIF
# provider's allowed-audiences, which is the full https://iam.googleapis.com/...
# provider URL (see google_cloud_init.md, gcloud ... --allowed-audiences=...).
identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

# --- prod: dedicated cluster + managed Cloud SQL (PITR + backups) -----------
deployment "prod" {
  inputs = {
    # Keyless auth: OIDC JWT exchanged via WIF to impersonate the apply SA.
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id  = local.gcp_project
    environment = "prod"
    region      = local.gcp_region
    zone        = local.gcp_zone

    # Single on-demand pool. The whole cluster is prod, so it is NOT tainted:
    # a lone tainted pool would leave kube-system / CoreDNS unschedulable.
    gke_regional            = false
    gke_deletion_protection = true
    gke_node_pools = {
      default = {
        machine_type = "e2-standard-2"
        spot         = false
        min_count    = 1
        max_count    = 2 # surge headroom during node upgrades
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "prod" }
        taints       = []
      }
    }

    master_authorized_networks = local.master_authorized_networks

    # Managed Postgres for prod: cheapest tier + PITR/backups (no HA at budget).
    cloudsql_enabled               = true
    cloudsql_tier                  = "db-f1-micro"
    cloudsql_availability_type     = "ZONAL"
    cloudsql_disk_size_gb          = 20
    cloudsql_pitr_enabled          = true
    cloudsql_backup_retained_count = 7
    cloudsql_txlog_retention_days  = 7
    cloudsql_deletion_protection   = true

    storage_force_destroy = false
    extra_labels          = { cost-center = "platform-prod" }
  }
}

# --- dev: minimized, single Spot node, in-cluster Postgres (no Cloud SQL) ----
deployment "dev" {
  inputs = {
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id  = local.gcp_project
    environment = "dev"
    region      = local.gcp_region
    zone        = local.gcp_zone

    # One cheap Spot pool runs everything on this cluster: kube-system, the dev
    # Mattermost, the in-cluster Postgres StatefulSet and matterbridge. Spot
    # pricing keeps the (unavoidable) second cluster's node cost minimal.
    gke_regional            = false
    gke_deletion_protection = false
    gke_node_pools = {
      default = {
        machine_type = "e2-medium" # 4Gi: headroom for system pods + dev stack
        spot         = true
        min_count    = 1
        max_count    = 2
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "dev" }
        taints       = []
      }
    }

    master_authorized_networks = local.master_authorized_networks

    # dev uses the in-cluster Postgres StatefulSet (platform/dev/), so the
    # managed Cloud SQL instance is skipped entirely to save ~$13/mo.
    cloudsql_enabled = false

    storage_force_destroy = true # dev buckets are disposable
    extra_labels          = { cost-center = "platform-dev" }
  }
}
