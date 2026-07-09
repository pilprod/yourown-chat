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
  description = "Environment name (drives naming and labels). The single-cluster budget default uses 'prod' as the platform cluster; dev workloads run as a tenant namespace on the dev node pool."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "project_prefix" {
  type        = string
  description = "Short platform prefix used in resource names."
  default     = "ycs"
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

variable "google_credentials" {
  type        = string
  description = "Optional SA/WIF credentials JSON, injected from an HCP store. Null when using OIDC dynamic credentials."
  default     = null
  sensitive   = true
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

# --- Labels -----------------------------------------------------------------
variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto every labellable resource."
  default     = {}
}
