# ---------------------------------------------------------------------------
# Deployments = environments.
#
# BUDGET TOPOLOGY (~$85–93/mo, ceiling $100): a single zonal GKE cluster (free
# control plane) hosts BOTH the prod and dev tiers via two node pools:
#   - prod pool: e2-standard-2, on-demand, tainted (dedicated=prod:NO_SCHEDULE)
#   - dev pool : e2-small, on-demand, untainted (kube-system + dev + bridge)
# Prod Postgres is managed Cloud SQL (db-f1-micro, PITR + 7d backups); dev runs
# an in-cluster Postgres on the dev pool. This is why there is ONE deployment
# here instead of three separate clusters — separate clusters per environment
# multiply the spend and blow the ceiling. The scale-out path (promote dev /
# stage to their own clusters once the budget is raised) is the commented
# example at the bottom.
#
# AUTH: keyless HCP Terraform Dynamic Provider Credentials -> GCP Workload
# Identity Federation. HCP mints the OIDC JWT below (aud = hcp.workload.identity,
# which must match the WIF provider's allowed_audiences); the google provider
# exchanges it and impersonates a least-privilege apply SA. Nothing secret lives
# in git. See docs/BOOTSTRAP.md for creating the pool/provider + SAs.
#
# Replace every REPLACE-ME-* value (project IDs, CIDRs, WIF audience, SA email)
# with real values before use.
# ---------------------------------------------------------------------------

identity_token "gcp" {
  audience = ["hcp.workload.identity"]
}

deployment "platform" {
  inputs = {
    # Keyless auth: OIDC JWT exchanged via WIF to impersonate the apply SA.
    identity_token        = identity_token.gcp.jwt
    audience              = "REPLACE-ME-WIF-AUDIENCE"   # //iam.googleapis.com/projects/<NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>
    service_account_email = "REPLACE-ME-APPLY-SA-EMAIL" # e.g. ycs-tf-apply@<project>.iam.gserviceaccount.com

    project_id  = "REPLACE-ME-platform-project"
    environment = "prod"
    region      = "europe-west3" # Frankfurt, Germany
    zone        = "europe-west3-b"

    # One zonal cluster, two isolated node pools.
    gke_regional            = false
    gke_deletion_protection = true
    gke_node_pools = {
      prod = {
        machine_type = "e2-standard-2"
        spot         = false
        min_count    = 1
        max_count    = 2 # headroom = surge during node upgrades only
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "prod" }
        taints       = [{ key = "dedicated", value = "prod", effect = "NO_SCHEDULE" }]
      }
      dev = {
        machine_type = "e2-small"
        spot         = false
        min_count    = 1
        max_count    = 1
        disk_size_gb = 30
        disk_type    = "pd-standard"
        labels       = { tier = "dev" }
        taints       = []
      }
    }

    # SECURITY: restrict the control-plane endpoint to your CI runner / office.
    master_authorized_networks = [
      { cidr_block = "REPLACE-ME/32", display_name = "ci-runner" },
    ]

    # Prod Postgres — cheapest tier + PITR/backups (no HA at this budget).
    cloudsql_tier                  = "db-f1-micro"
    cloudsql_availability_type     = "ZONAL"
    cloudsql_disk_size_gb          = 20
    cloudsql_pitr_enabled          = true
    cloudsql_backup_retained_count = 7
    cloudsql_txlog_retention_days  = 7
    cloudsql_deletion_protection   = true

    storage_force_destroy = false

    extra_labels = { cost-center = "platform" }
  }
}

# ---------------------------------------------------------------------------
# SCALE-OUT EXAMPLE (disabled). Uncomment once the budget is raised to run a
# fully isolated environment on its own cluster + managed Postgres. Each such
# deployment roughly adds the single-cluster cost again.
# ---------------------------------------------------------------------------
# deployment "stage" {
#   inputs = {
#     identity_token        = identity_token.gcp.jwt
#     audience              = "REPLACE-ME-WIF-AUDIENCE"
#     service_account_email = "REPLACE-ME-APPLY-SA-EMAIL"
#
#     project_id  = "REPLACE-ME-stage-project"
#     environment = "stage"
#     region      = "europe-west3"
#     zone        = "europe-west3-b"
#
#     gke_regional = false
#     gke_node_pools = {
#       prod = {
#         machine_type = "e2-standard-2"
#         labels       = { tier = "prod" }
#         taints       = [{ key = "dedicated", value = "prod", effect = "NO_SCHEDULE" }]
#       }
#       dev = { machine_type = "e2-small", max_count = 1, labels = { tier = "dev" } }
#     }
#
#     master_authorized_networks = [
#       { cidr_block = "REPLACE-ME/32", display_name = "ci-runner" },
#     ]
#
#     cloudsql_tier              = "db-custom-1-3840"
#     cloudsql_availability_type = "ZONAL"
#     cloudsql_disk_size_gb      = 20
#
#     storage_force_destroy = false
#     extra_labels          = { cost-center = "platform-stage" }
#   }
# }
