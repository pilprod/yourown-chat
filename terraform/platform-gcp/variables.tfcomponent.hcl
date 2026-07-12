# ---------------------------------------------------------------------------
# PLATFORM stack inputs. Values are supplied per-environment by the deployment
# blocks in platform.tfdeploy.hcl. One deployment (eu) provisions the stateful
# foundation: APIs, network, CMEK, GKE, Cloud SQL, object storage, the
# container registry and the Workload Identity SAs. The delivery layer lives in
# the sibling CLOUDFLARE and APP-GCP stacks, linked via publish_output/upstream_input.
#
# Naming: resources are named by ROLE (Workload Identity SAs) or REGIONALLY
# (europe-west3-*), never by environment or project -- the project is already
# `yourown-chat`, so a yourown-chat-* prefix would just repeat it. `environment`
# drives labels only.
#
# TOPOLOGY: the budget-optimized default is ONE zonal GKE cluster with two node
# pools (prod + dev tiers) instead of separate clusters per environment. See
# platform.tfdeploy.hcl and the README for the rationale and the scale-out path.
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID for this environment."
}

variable "environment" {
  type        = string
  description = "Environment name (drives labels only; resource names are role-based or regional, never environment-scoped). The single-cluster budget default uses 'prod' as the platform cluster; dev workloads run as a tenant namespace on the dev node pool."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "region" {
  type        = string
  description = "Primary region. europe-west3 = Frankfurt, Germany. Also the Artifact Registry region."
  default     = "europe-west3"
}

variable "zone" {
  type        = string
  description = "Zone used for a zonal (cheapest) GKE cluster and the ZONAL Cloud SQL instance."
  default     = "europe-west3-b"
}

# --- Keyless auth: HCP Dynamic Provider Credentials -> GCP WIF ---------------
# No static credentials, SA keys, or JSON exist anywhere in this repo. HCP mints
# a short-lived OIDC JWT per run (identity_token block in platform.tfdeploy.
# hcl); the google provider exchanges it through Workload Identity Federation
# and impersonates a least-privilege service account. See README.md.
variable "identity_token" {
  type        = string
  ephemeral   = true
  description = "HCP Terraform OIDC JWT, minted per run. Ephemeral: never persisted to stack state."
}

variable "audience" {
  type        = string
  description = "STS audience = full WIF provider resource name (//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID>)."
}

variable "service_account_email" {
  type        = string
  description = "Least-privilege GCP apply SA impersonated by Terraform via WIF (never Owner/Editor)."
}

# --- Container registry ------------------------------------------------------
variable "artifact_registry_repository_id" {
  type        = string
  description = "ID of the unified Artifact Registry repository the stack creates (shared across environments; images are promoted by tag, not duplicated per env). The app-gcp stack's image CI pushes to it."
  default     = "docker"
}

variable "artifact_registry_kms_key_name" {
  type        = string
  description = "Optional CMEK key (full resource ID) for the registry. The container registry is PUBLIC, so this is null by default (Google-managed keys)."
  default     = null
}

variable "artifact_registry_vulnerability_scanning" {
  type        = bool
  description = "Automatically scan images pushed to the unified registry (i.e. the Mattermost image the CI builds) for vulnerabilities via Artifact Analysis. Enables the containerscanning API and sets the repository's vulnerability_scanning_config to INHERITED. Paid: ~$0.26 per scanned image digest; default off."
  default     = false
}

# --- GKE cost / topology knobs ---------------------------------------------
variable "gke_regional" {
  type        = bool
  description = "true = regional (HA) control plane; false = zonal (cheapest, free tier)."
  default     = false
}

variable "gke_node_pools" {
  type = map(object({
    machine_type = optional(string, "e2-small")
    spot         = optional(bool, false)
    min_count    = optional(number, 1)
    max_count    = optional(number, 2)
    disk_size_gb = optional(number, 30)
    disk_type    = optional(string, "pd-standard")
    labels       = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  description = "Map of node pool name => spec. Isolate workload tiers on one cluster via labels/taints (e.g. a tainted prod pool + an untainted dev pool)."

  default = {
    prod = {
      machine_type = "e2-standard-2"
      spot         = false
      min_count    = 1
      max_count    = 2
      disk_size_gb = 30
      labels       = { tier = "prod" }
      taints       = [{ key = "dedicated", value = "prod", effect = "NO_SCHEDULE" }]
    }
    dev = {
      machine_type = "e2-medium"
      spot         = false
      min_count    = 1
      max_count    = 2
      disk_size_gb = 30
      labels       = { tier = "dev" }
      taints       = []
    }
  }
}

variable "gke_deletion_protection" {
  type        = bool
  description = "Protect the GKE cluster from deletion."
  default     = true
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the GKE control-plane endpoint."
  default     = []
}

# --- Cloud SQL cost / HA / backup knobs ------------------------------------
variable "cloudsql_enabled" {
  type        = bool
  description = "Provision a managed Cloud SQL instance. Set false for cost-minimized environments (e.g. dev) that use the in-cluster Postgres StatefulSet instead."
  default     = true
}

variable "cloudsql_tier" {
  type        = string
  description = "Cloud SQL machine tier."
  default     = "db-f1-micro"
}

variable "cloudsql_availability_type" {
  type        = string
  description = "ZONAL (cheapest) or REGIONAL (HA)."
  default     = "ZONAL"
}

variable "cloudsql_disk_size_gb" {
  type        = number
  description = "Cloud SQL initial disk size."
  default     = 20
}

variable "cloudsql_pitr_enabled" {
  type        = bool
  description = "Enable point-in-time recovery (WAL archiving). Cheap insurance against data loss without HA."
  default     = true
}

variable "cloudsql_backup_retained_count" {
  type        = number
  description = "Number of automated backups to retain."
  default     = 7
}

variable "cloudsql_txlog_retention_days" {
  type        = number
  description = "Days of transaction logs retained for PITR."
  default     = 7
}

variable "cloudsql_deletion_protection" {
  type        = bool
  description = "Protect the Cloud SQL instance from deletion."
  default     = true
}

variable "cloudsql_adopt_existing_instance" {
  type        = bool
  description = "Import a same-named Cloud SQL instance already present in the project into state instead of creating it. Use to adopt an instance orphaned by a create-wait timeout (Cloud SQL reserves a deleted name for ~1 week, so delete+recreate is not an option). Set true for one apply, then back to false."
  default     = false
}

# --- Storage ----------------------------------------------------------------
variable "storage_force_destroy" {
  type        = bool
  description = "Allow Terraform to delete the bucket even if it is non-empty."
  default     = false
}

# --- Encryption (CMEK) ------------------------------------------------------
# One shared Cloud KMS key encrypts every at-rest store that supports CMEK
# (Cloud SQL, GCS, Secret Manager -- including the app-gcp stack's secrets and its
# release-source bucket, which receive the key id via upstream_input). At-rest
# data is AES-256 either way; CMEK puts the key lifecycle (rotation, disable,
# destroy = crypto-shred) under our control instead of Google's. The PUBLIC
# Artifact Registry is deliberately not CMEK-encrypted, so it takes no key.
variable "cmek_enabled" {
  type        = bool
  description = "Provision the shared Cloud KMS key and encrypt Cloud SQL + GCS + Secret Manager with it. Cost is ~$1/mo for an HSM key version (or ~$0.06 for SOFTWARE). Note: Cloud SQL binds its key at creation, so toggling this on an existing deployment replaces that instance."
  default     = true
}

variable "kms_protection_level" {
  type        = string
  description = "CMEK key protection level. HSM = FIPS 140-2 Level 3 hardware custody (~$1.00/version/mo); SOFTWARE = Level 1 (~$0.06). Immutable once the key exists -- moving between them later means a new key (and, for Cloud SQL, an instance migration)."
  default     = "HSM"

  validation {
    condition     = contains(["HSM", "SOFTWARE"], var.kms_protection_level)
    error_message = "kms_protection_level must be HSM or SOFTWARE."
  }
}

variable "kms_rotation_period" {
  type        = string
  description = "Automatic rotation period for the shared key, in seconds with an 's' suffix. Default 90 days."
  default     = "7776000s"
}

# --- Public ingress ----------------------------------------------------------
variable "public_ingress_enabled" {
  type        = bool
  description = "Reserve the static external ingress IP (the Cloudflare-facing 'white address'). The cloudflare stack's apex A record consumes it via upstream_input, and its edge component is gated on the SAME flag there -- keep the values in sync. Enable for prod only; dev stays private."
  default     = false
}

# --- Labels -----------------------------------------------------------------
variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto every labellable resource."
  default     = {}
}

variable "kms_adopt_existing" {
  type        = bool
  description = "Import the same-named KMS key ring + crypto key already present in the project instead of creating them. Cloud KMS objects can never be deleted from GCP, so re-bootstrapping an existing project (e.g. after a manual teardown) always needs this on -- a fresh create 409s. Safe to leave on: the import is a no-op once both are in state."
  default     = false
}

variable "cloudsql_password_rotation" {
  type        = string
  description = "Rotation trigger for the Cloud SQL user password. Bump the committed value in platform.tfdeploy.hcl (e.g. to a date) and apply: the password, SQL user and both Secret Manager secrets update in one apply -- then restart the Mattermost pods (the CSI mount refreshes on pod start). A committed literal on purpose: varset values are ephemeral in Stacks and cannot feed persisted state, and time-based keepers would rotate as a side effect of unrelated applies."
  default     = "1"
}
