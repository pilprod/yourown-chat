# ---------------------------------------------------------------------------
# PLATFORM deployments. ONE deployment (`eu`) provisions the stateful
# foundation in the single GCP project `yourown-chat`, europe-west3: enabled
# APIs, network (+ reserved ingress IP), CMEK, one zonal GKE cluster with two
# node pools, managed Cloud SQL, object storage, the container registry and
# the Workload Identity SAs.
#
# The delivery layer (secrets, Cloud Deploy pipeline, image CI, release
# cutting, Cloudflare edge) is split across the sibling CLOUDFLARE and APP-GCP stacks, LINKED to this
# one: the publish_output blocks below are its upstream contract. The app
# stack only ever consumes last-APPLIED values, so HCP orders the two stacks
# automatically (platform apply -> app plan is triggered) and an app-side
# mistake can never touch platform state.
#
# TOPOLOGY / COST: GKE's free tier waives the management fee for ONE zonal
# cluster per billing account, so this single-cluster shape stays ~$98-106/mo
# (vs ~$150-160/mo for a physically separate dev cluster). Isolation between
# dev and prod is achieved in-cluster: a tainted prod pool (e2-standard-2), an
# untainted dev/system pool (e2-medium) that also hosts kube-system, and namespace
# RBAC + default-deny NetworkPolicies. The dev pool is on-demand (NOT Spot) on
# purpose: it runs CoreDNS/kube-system, which must not be preempted under prod.
#
# AUTH: keyless HCP Terraform Dynamic Provider Credentials -> Workload
# Identity Federation (identity_token block; no static keys, no TFC_GCP_*).
# HCP mints the OIDC JWT; its `aud` MUST be one of the WIF provider's
# allowed-audiences. The google provider exchanges it at STS and impersonates
# the least-privilege apply SA. Nothing secret is committed. Bootstrap:
# README.md.
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

# NO varset store here -- and none can work for plan-persisted values. Stacks
# treats every `store` value as EPHEMERAL: fine for credentials read by an
# ephemeral variable (the cloudflare stack's API token), but a config toggle
# (API list, repository settings) must persist into the plan, and HCP rejects
# ephemeral values there ("Cannot use an ephemeral value for input variable").
# On top of the earlier lessons (no tobool(); a missing key = null), the rule
# is: varsets carry SECRETS ONLY; operational toggles are committed literals
# in this file.

# --- eu: the stateful foundation in one deployment ---------------------------
# environment = "prod" makes this the prod-grade platform cluster; the dev tenant
# lives on it as an isolated namespace on the dev node pool. public_ingress is
# on, so the Cloudflare-facing static IP is reserved for the cloudflare stack's edge.
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
    #   dev  - e2-medium, on-demand, UNTAINTED so kube-system/CoreDNS + the dev
    #          tenant (nodeSelector tier=dev) share this cheap system pool.
    #          min=1 keeps idle cost low; max=3 gives autoscaler headroom when
    #          system pods are pending or a node is cordoned during replacement.
    #          On-demand, not Spot: preempting this pool would take CoreDNS down
    #          for prod.
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
    # DB password rotation trigger. To rotate: change this value (a date works
    # well), merge, apply, then `kubectl rollout restart -n mattermost` so the
    # pods pick up the new connection secret. Committed literal by design --
    # varsets are ephemeral-only, and each bump leaves a dated git record.
    cloudsql_password_rotation = "2026-07-12"

    # --- Public ingress -------------------------------------------------------
    # Reserves the Cloudflare-facing static IP the cloudflare stack's apex A record
    # points at. Keep in sync with the app deployment's public_ingress_enabled.
    public_ingress_enabled = true

    # --- Encryption: one shared Cloud KMS HSM key (FIPS 140-2 Level 3) --------
    # Encrypts Cloud SQL + GCS + Secret Manager (the app-gcp stack reuses the key
    # via cmek_key_id). ~$1/mo for the single HSM key version. Set cmek_enabled
    # = false (or protection_level = "SOFTWARE", ~$0.06/mo) to trade custody
    # assurance for cost.
    cmek_enabled         = true
    kms_protection_level = "HSM"
    # The ring (europe-west3) + key (cmek) already exist from the previous
    # bootstrap and can never be deleted from GCP -- adopt them into state
    # instead of 409-ing on create. No-op on every apply after the first.
    kms_adopt_existing = true

    storage_force_destroy = false

    # The container registry is PUBLIC -> no CMEK (null).
    artifact_registry_kms_key_name = null
    # Vulnerability scanning for the built Mattermost image (Artifact
    # Analysis, ~$0.26 per scanned digest). A committed literal on purpose:
    # varset values are ephemeral in Stacks and cannot reach plan-persisted
    # config (see the note above the deployment).
    artifact_registry_vulnerability_scanning = true

    extra_labels = { cost-center = "platform" }
  }
}

# --- Linked-stack contract: values the CLOUDFLARE and APP-GCP stacks consume --------------------
# Each publish_output republishes a stack output of the LAST APPLIED state of
# deployment.eu. Downstream stacks reference them as
#   upstream_input.platform.<name>
# and HCP automatically triggers an app plan whenever an apply here changes one.
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
