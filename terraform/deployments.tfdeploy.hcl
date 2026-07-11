# ---------------------------------------------------------------------------
# Deployments = environments. ONE Terraform Stacks deployment (`eu`)
# provisions the WHOLE product in the single GCP project `yourown-chat`, in
# europe-west3 (eu): the platform (one zonal GKE cluster with two node pools,
# managed Cloud SQL, object storage, secrets), the image-build CI (Artifact
# Registry + Cloud Build 2nd-gen), and the Cloudflare edge -- all as components
# of this one stack. dev is NOT a second cluster: it is an isolated tenant
# NAMESPACE on this same cluster (RBAC + NetworkPolicy), scheduled onto its own
# node pool. Resources are named by role (Workload Identity SAs) or regionally
# (europe-west3-*), never by environment.
#
# Add environments as ADDITIONAL deployments (e.g. stage-eu, dev-eu) -- each is
# a separate instance of the whole stack with its own state. NOTE for a future
# multi-deployment world: if two deployments ever share ONE Cloudflare zone, the
# zone-level singletons (zone settings, DNSSEC, WAF) must NOT be co-owned by
# both -- split them into a shared component and keep only per-env DNS records in
# each deployment. Not a concern with this single eu deployment.
#
# TOPOLOGY / COST: GKE's free tier waives the management fee for ONE zonal
# cluster per billing account, so this single-cluster shape stays ~$86-93/mo
# (vs ~$140-150/mo for a physically separate dev cluster). Isolation between dev
# and prod is achieved in-cluster: a tainted prod pool (e2-standard-2), an
# untainted dev pool (e2-small) that also hosts kube-system, and namespace RBAC
# + default-deny NetworkPolicies. The dev pool is on-demand (NOT Spot) on
# purpose: it runs CoreDNS/kube-system, which must not be preempted under prod.
#
# AUTH is mixed by necessity:
#   - GCP: keyless HCP Terraform Dynamic Provider Credentials -> Workload
#     Identity Federation (identity_token block; no static keys, no TFC_GCP_*).
#     HCP mints the OIDC JWT; its `aud` MUST be one of the WIF provider's
#     allowed-audiences. The google provider exchanges it at STS and impersonates
#     the least-privilege apply SA. Nothing secret is committed.
#   - Cloudflare: no Workload Identity path, so a single zone-scoped API token is
#     pulled from an HCP variable set (store "varset") and passed as an EPHEMERAL
#     input -- never in git or state. Only exercised when public_ingress_enabled.
# Bootstrap (both): README.md.
# ---------------------------------------------------------------------------

locals {
  # --- Keyless GCP auth wiring (project `yourown-chat`) ----------------------
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
# provider URL (see README.md, gcloud ... --allowed-audiences=...).
identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

# Cloudflare zone-scoped API token, injected from an HCP variable set so it never
# touches git or state. Replace the id with your workspace's variable set ID and
# store the token under the key `cloudflare_api_token`. See README.md.
store "varset" "cloudflare" {
  id       = "varset-wrrdzyQKCP2no9U6"
  category = "terraform"
}

# --- eu: the whole product in one deployment ---------------------------
# environment = "prod" makes this the prod-grade platform cluster; the dev tenant
# lives on it as an isolated namespace on the dev node pool. public_ingress is on,
# so the Cloudflare edge component and the origin-TLS secrets are provisioned.
deployment "eu" {
  inputs = {
    # --- Keyless GCP auth: OIDC JWT exchanged via WIF to impersonate apply SA --
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id  = local.gcp_project
    environment = "prod"
    region      = local.gcp_region
    zone        = local.gcp_zone

    # --- GKE: ONE zonal cluster, TWO node pools sharing it -------------------
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

    # --- Managed Postgres for prod (cheapest tier + PITR/backups, no HA) ------
    # The dev tenant uses its own in-cluster Postgres StatefulSet, so only prod
    # consumes this instance.
    cloudsql_enabled               = true
    cloudsql_tier                  = "db-f1-micro"
    cloudsql_availability_type     = "ZONAL"
    cloudsql_disk_size_gb          = 20
    cloudsql_pitr_enabled          = true
    cloudsql_backup_retained_count = 7
    cloudsql_txlog_retention_days  = 7
    cloudsql_deletion_protection   = true

    # --- Public ingress + Cloudflare edge ------------------------------------
    # Reserves the Cloudflare-facing static IP, creates the origin-TLS secret
    # containers, AND provisions the Cloudflare component (DNS/settings/WAF). The
    # apex A record is wired live to the reserved IP; the Origin CA cert flows
    # straight into the mattermost-origin-tls-* secrets. Only prod is exposed.
    public_ingress_enabled = true

    # --- Encryption: one shared Cloud KMS HSM key (FIPS 140-2 Level 3) --------
    # Encrypts Cloud SQL + GCS + Secret Manager. ~$1/mo for the single HSM key
    # version. Set cmek_enabled = false (or protection_level = "SOFTWARE",
    # ~$0.06/mo) to trade custody assurance for cost.
    cmek_enabled         = true
    kms_protection_level = "HSM"

    storage_force_destroy = false

    # --- Image-build CI ------------------------------------------------------
    # The Cloud Build 2nd-gen GitHub connection is authorized once out-of-band in
    # the console (OAuth) and named here; both the image and deploy repos are
    # linked to it (see README.md).
    github_connection_name = "pilprod-github"
    github_remote_uri      = "https://github.com/pilprod/mattermost.git"
    image_name             = "mattermost"
    # The container registry is PUBLIC -> no CMEK (null).
    artifact_registry_kms_key_name = null
    # One source repo, ONE unified registry, ONE image built on a single tag
    # pattern. The same artifact is promoted dev -> prod (Cloud Deploy):
    #   v9.11.3-patched  -> docker/mattermost:v9.11.3-patched
    builds = {
      mattermost = { tag_regex = "^v.*-patched$" }
    }

    # --- Automated release cutting ------------------------------------------
    # THIS repo (holds helm/) is linked to the SAME shared connection: a semver
    # tag (MAJOR.MINOR.PATCH) cuts a Cloud Deploy release automatically — no
    # manual `gcloud deploy releases create`. The connection must cover this repo.
    github_deploy_remote_uri = "https://github.com/pilprod/yourown-chat.git"
    release_tag_regex        = "^[0-9]+\\.[0-9]+\\.[0-9]+$"

    # --- Cloudflare edge (token from the varset; IP wired live in the stack) --
    cloudflare_api_token          = store.varset.cloudflare.cloudflare_api_token
    domain                        = "yourown.chat"
    cloudflare_proxied            = true
    cloudflare_ssl_mode           = "strict"
    cloudflare_always_use_https   = "on"
    cloudflare_min_tls_version    = "1.3"
    cloudflare_dnssec_enabled     = true
    cloudflare_manage_origin_cert = true

    extra_labels = { cost-center = "platform" }
  }
}
