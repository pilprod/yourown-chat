# ---------------------------------------------------------------------------
# Deployments = environments. ONE Terraform Stacks deployment provisions the
# whole platform in the single GCP project `yourown-chat`: one zonal GKE cluster
# with TWO node pools, managed Cloud SQL, object storage and the public ingress.
# dev is NOT a second cluster -- it is an isolated tenant NAMESPACE on this same
# cluster (RBAC + NetworkPolicy, see platform/dev/), scheduled onto its own node
# pool. All resources are prefixed `ycs-prod-*` (environment = "prod"); the dev
# tenant's GCP objects (its Workload Identity SA, its in-cluster Postgres
# password secret) are created by this one deployment under that same prefix.
#
# TOPOLOGY / COST: GKE's free tier waives the management fee for ONE zonal
# cluster per billing account, so this single-cluster shape stays ~$86-93/mo
# (vs ~$140-150/mo for a physically separate dev cluster). Isolation between dev
# and prod is achieved in-cluster:
#   - a dedicated, tainted prod node pool (e2-standard-2, dedicated=prod) so dev
#     workloads can never contend with prod for CPU/memory, and
#   - an untainted dev node pool (e2-small) that also hosts kube-system so the
#     dev tenant + system pods share the cheap pool, and
#   - namespace RBAC + default-deny NetworkPolicies scoping the dev tenant.
# The dev pool is on-demand (NOT Spot) on purpose: it also runs CoreDNS and the
# rest of kube-system, which must not be preempted out from under prod.
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
  # --- Keyless auth wiring (project `yourown-chat`) --------------------------
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

# --- platform: one cluster (prod + dev pools), managed Cloud SQL, ingress ----
# environment = "prod" makes this the prod-grade platform cluster; the dev
# tenant lives on it as an isolated namespace on the dev node pool.
deployment "platform" {
  inputs = {
    # Keyless auth: OIDC JWT exchanged via WIF to impersonate the apply SA.
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id  = local.gcp_project
    environment = "prod"
    region      = local.gcp_region
    zone        = local.gcp_zone

    # ONE zonal cluster, TWO node pools sharing it:
    #   prod - e2-standard-2, on-demand, TAINTED dedicated=prod so ONLY prod
    #          workloads (which tolerate it + nodeSelector tier=prod) land here.
    #   dev  - e2-small, on-demand, UNTAINTED so kube-system/CoreDNS + the dev
    #          tenant (nodeSelector tier=dev) share this cheap pool. On-demand,
    #          not Spot: preempting this pool would take CoreDNS down for prod.
    gke_regional            = false
    gke_deletion_protection = true
    gke_node_pools = {
      prod = {
        machine_type = "e2-standard-2"
        spot         = false
        min_count    = 1
        max_count    = 2 # surge headroom during node upgrades
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "prod" }
        taints       = [{ key = "dedicated", value = "prod", effect = "NO_SCHEDULE" }]
      }
      dev = {
        machine_type = "e2-small"
        spot         = false
        min_count    = 1
        max_count    = 2
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "dev" }
        taints       = []
      }
    }

    master_authorized_networks = local.master_authorized_networks

    # Managed Postgres for prod: cheapest tier + PITR/backups (no HA at budget).
    # The dev tenant uses its own in-cluster Postgres StatefulSet (platform/dev/),
    # so only prod consumes this instance.
    cloudsql_enabled               = true
    cloudsql_tier                  = "db-f1-micro"
    cloudsql_availability_type     = "ZONAL"
    cloudsql_disk_size_gb          = 20
    cloudsql_pitr_enabled          = true
    cloudsql_backup_retained_count = 7
    cloudsql_txlog_retention_days  = 7
    cloudsql_deletion_protection   = true

    # Public ingress: reserve the Cloudflare-facing static IP + origin-protection
    # secret containers (origin TLS keypair + Authenticated Origin Pulls CA).
    # Only prod Mattermost is exposed; the dev tenant stays private.
    public_ingress_enabled = true

    storage_force_destroy = false
    extra_labels          = { cost-center = "platform" }
  }
}
