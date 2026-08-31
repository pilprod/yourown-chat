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
# TOPOLOGY: the budget-optimized default is ONE zonal GKE cluster with an
# autoscaling general pool shared by application workloads and standalone RTCD.
# Kubernetes priorities, requests and quotas isolate workload tiers. See
# platform.tfdeploy.hcl and the README for the rationale and the scale-out path.
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID for this environment."
}

variable "project_number" {
  type        = string
  description = "Numeric project number (from the WIF audience). Used to build the GKE service-agent email for the etcd Secrets-encryption KMS grant."
}

variable "billing_account_id" {
  type        = string
  description = "Cloud Billing account exported to the project BigQuery dataset."
}

variable "environment" {
  type        = string
  description = "Environment name (drives labels only; resource names are role-based or regional, never environment-scoped). The single-cluster budget default uses 'prod' as the platform cluster; dev workloads run as low-priority tenants on the shared node pool."

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

variable "helm_registry_repository_id" {
  type        = string
  description = "ID of the Artifact Registry repository that stores the platform Helm workload-profile charts as immutable OCI artifacts (helm/platform). Service release wrappers pin exact chart versions from it; app-gcp publishes charts into it and reads from it at release time."
  default     = "helm"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.helm_registry_repository_id))
    error_message = "helm_registry_repository_id must be lowercase alphanumeric/hyphen, starting with a letter."
  }
}

variable "kagent_registry_repository_id" {
  type        = string
  description = "ID of the dedicated immutable Artifact Registry repository for reviewed kagent fork preview images and OCI charts. app-gcp owns publication; platform-gcp owns the repository lifecycle."
  default     = "kagent-preview"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.kagent_registry_repository_id))
    error_message = "kagent_registry_repository_id must be lowercase alphanumeric/hyphen, starting with a letter."
  }
}

variable "kagent_staging_registry_repository_id" {
  type        = string
  description = "ID of the dedicated private Artifact Registry staging repository used by app-gcp to build and scan kagent candidates before immutable promotion into the private release repository."
  default     = "kagent-staging"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.kagent_staging_registry_repository_id))
    error_message = "kagent_staging_registry_repository_id must be lowercase alphanumeric/hyphen, starting with a letter."
  }
}

variable "artifact_registry_vulnerability_scanning" {
  type        = bool
  description = "Default repository scanning gate. Keep false for routine builds; the production Google Cloud MCP opens bounded paid scan windows when explicitly approved."
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
    machine_type   = optional(string, "e2-small")
    spot           = optional(bool, false)
    min_count      = optional(number, 1)
    max_count      = optional(number, 2)
    disk_size_gb   = optional(number, 30)
    disk_type      = optional(string, "pd-standard")
    cmek_boot_disk = optional(bool, false)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  description = "Map of node pool name => spec. The default uses one autoscaling pool; Kubernetes PriorityClass and namespace quotas isolate workload tiers."

  default = {
    general = {
      machine_type = "e2-standard-2"
      spot         = false
      min_count    = 1
      max_count    = 3
      disk_size_gb = 30
      labels = {
        pool = "general"
      }
      taints = []
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

variable "cloudsql_studio_users" {
  type        = set(string)
  description = "Google user emails allowed to sign in through Cloud SQL Studio with database-level read-only access."
  default     = []
}

variable "yourown_chat_server_enabled" {
  type        = bool
  description = "Publish the independent YourOwn.Chat server plane as enabled to downstream delivery. Its low-cost logical database is retained when runtime delivery is disabled."
  default     = true
}

variable "yourown_chat_identity_password_rotation" {
  type        = string
  description = "Explicit rotation trigger for the YourOwn.Chat identity database roles."
  default     = "1"
}

variable "additional_database_users" {
  type = map(object({
    database_names                = set(string)
    adopt_existing_database_names = optional(set(string), [])
    password_secret_id            = string
    connection_secret_id          = optional(string)
    password_rotation             = optional(string, "1")
    manage_databases              = optional(bool, true)
    connection_secret_accessors   = optional(set(string), [])
    kubernetes_connection_secret_accessors = optional(set(object({
      namespace       = string
      service_account = string
    })), [])
  }))
  description = "Service-owned requests for additional logical database roles on the shared protected Cloud SQL instance. Set adopt_existing_database_names only for a reviewed one-shot import, then clear it after success; the imported resources remain managed in state."
  default     = {}

  validation {
    condition = alltrue([
      for user_name, settings in var.additional_database_users :
      can(regex("^[a-z_][a-z0-9_]*$", user_name)) &&
      !contains(["mattermost", "temporal", "yourown_chat_identity", "yourown_chat_identity_runtime"], user_name) &&
      length(settings.database_names) > 0 &&
      alltrue([for database_name in settings.database_names : can(regex("^[a-z_][a-z0-9_]*$", database_name))]) &&
      (settings.connection_secret_id == null || length(settings.database_names) == 1)
    ])
    error_message = "Additional Cloud SQL users require non-reserved PostgreSQL-safe names and connection URI secrets may target exactly one database."
  }

  validation {
    condition = alltrue([
      for settings in values(var.additional_database_users) :
      length(setsubtract(settings.adopt_existing_database_names, settings.database_names)) == 0 &&
      (settings.manage_databases || length(settings.adopt_existing_database_names) == 0)
    ])
    error_message = "Only explicitly named databases managed by platform-gcp may be adopted."
  }
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
  description = "Provision the shared Cloud KMS key for Cloud SQL, GCS, Secret Manager, GKE etcd, sensitive PVCs and opted-in node boot disks. Cost is ~$1/mo for an HSM key version (or ~$0.06 for SOFTWARE). Cloud SQL and node boot disks bind their key at creation, so enabling it later requires resource replacement."
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

variable "mattermost_calls_enabled" {
  type        = bool
  description = "Provision the stable external media IP used by Mattermost RTCD."
  default     = false
}

variable "agentgateway_enabled" {
  type        = bool
  description = "Install the official agentgateway control plane plus its pinned Gateway API/agentgateway CRDs."
  default     = false
}

variable "agentgateway_public_ip_enabled" {
  type        = bool
  description = "Request a dedicated regional public IP for the application-owned agentgateway data plane. The component gates this request on agentgateway_enabled so a disabled control plane can never reserve the address."
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

# --- Temporal platform service ----------------------------------------------
variable "temporal_enabled" {
  type        = bool
  description = "Create the Temporal logical databases, result bucket and pinned official chart inside platform-gcp."
  default     = false
}

variable "temporal_chart_version" {
  type        = string
  description = "Pinned official Temporal Helm chart version."
  default     = "1.2.0"
}

variable "temporal_password_rotation" {
  type        = string
  description = "Explicit rotation trigger for the Temporal database user."
  default     = "1"
}
