# ---------------------------------------------------------------------------
# Stack inputs. Values are supplied per-environment by deployment blocks in
# deployments.tfdeploy.hcl. Cost/HA-sensitive knobs are exposed so the platform
# can be hardened without touching module code.
#
# TOPOLOGY: the budget-optimized default is ONE zonal cluster with two node
# pools (prod + dev tiers) instead of separate clusters per environment. See
# deployments.tfdeploy.hcl and the README for the rationale and the scale-out
# path (raising the budget to run stage/prod as separate clusters).
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID for this environment."
}

variable "environment" {
  type        = string
  description = "Environment name (drives labels only; resource names use the tier-neutral project_prefix). The single-cluster budget default uses 'prod' as the platform cluster; dev workloads run as a tenant namespace on the dev node pool."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "project_prefix" {
  type        = string
  description = "Short platform prefix used in resource names."
  default     = "yourown-chat"
}

variable "region" {
  type        = string
  description = "Primary region. europe-west3 = Frankfurt, Germany."
  default     = "europe-west3"
}

variable "zone" {
  type        = string
  description = "Zone used for a zonal (cheapest) GKE cluster."
  default     = "europe-west3-b"
}

# --- Keyless auth: HCP Dynamic Provider Credentials -> GCP WIF ---------------
# No static credentials, SA keys, or JSON exist anywhere in this repo. HCP mints
# a short-lived OIDC JWT per run (identity_token block in deployments.tfdeploy.
# hcl); the google provider exchanges it through Workload Identity Federation
# and impersonates a least-privilege service account. See docs/google_cloud_init.md.
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
  description = "Least-privilege GCP service account impersonated by Terraform via WIF (never Owner/Editor)."
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
      machine_type = "e2-small"
      spot         = false
      min_count    = 1
      max_count    = 1
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

# --- Storage ----------------------------------------------------------------
variable "storage_force_destroy" {
  type        = bool
  description = "Allow Terraform to delete the bucket even if it is non-empty."
  default     = false
}

# --- Encryption (CMEK) ------------------------------------------------------
# One shared Cloud KMS key encrypts every at-rest store that supports CMEK
# (Cloud SQL, GCS, and -- from the build stack -- Artifact Registry). At-rest
# data is AES-256 either way; CMEK puts the key lifecycle (rotation, disable,
# destroy = crypto-shred) under our control instead of Google's.
variable "cmek_enabled" {
  type        = bool
  description = "Provision the shared Cloud KMS key and encrypt Cloud SQL + GCS with it (and grant the Artifact Registry agent so the build stack can too). Cost is ~$1/mo for an HSM key version (or ~$0.06 for SOFTWARE). Note: Cloud SQL and Artifact Registry bind their key at creation, so toggling this on an existing deployment replaces those resources."
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

# --- Public ingress (Cloudflare-fronted) ------------------------------------
variable "public_ingress_enabled" {
  type        = bool
  description = "Provision the public ingress path for this environment: a reserved static IP (the Cloudflare-facing 'white address') plus the Secret Manager containers for the origin TLS keypair and the Authenticated Origin Pulls CA. Enable for prod only; dev stays private."
  default     = false
}

# --- Labels -----------------------------------------------------------------
variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto every labellable resource."
  default     = {}
}
