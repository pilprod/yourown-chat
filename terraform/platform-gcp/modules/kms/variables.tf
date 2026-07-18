variable "project_id" {
  type        = string
  description = "Project the key ring and key are created in."
}

variable "location" {
  type        = string
  description = "KMS location. Must match the region of every CMEK consumer (Cloud SQL instance, GCS bucket, Artifact Registry repo), e.g. 'europe-west3'. Also used as the keyring name prefix."
}

variable "protection_level" {
  type        = string
  description = "Key protection level. HSM = FIPS 140-2 Level 3 hardware custody (~$1.00/active version/mo); SOFTWARE = Level 1 (~$0.06). Immutable once the key is created."
  default     = "HSM"

  validation {
    condition     = contains(["HSM", "SOFTWARE"], var.protection_level)
    error_message = "protection_level must be HSM or SOFTWARE."
  }
}

variable "rotation_period" {
  type        = string
  description = "Automatic rotation period for the symmetric key, in seconds with an 's' suffix (KMS minimum is 24h). Default is 90 days."
  default     = "7776000s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.rotation_period))
    error_message = "rotation_period must be a number of seconds with an 's' suffix, e.g. '7776000s'."
  }
}

# --- Which per-project Google service agents get encrypt/decrypt on the key ---
# Each Google service encrypts CMEK data with its own per-project service agent,
# which must hold roles/cloudkms.cryptoKeyEncrypterDecrypter on the key.
variable "grant_cloudsql" {
  type        = bool
  description = "Grant the Cloud SQL service agent (service-<num>@gcp-sa-cloud-sql) encrypterDecrypter on the key."
  default     = true
}

variable "grant_storage" {
  type        = bool
  description = "Grant the Cloud Storage service agent (service-<num>@gs-project-accounts) encrypterDecrypter on the key."
  default     = true
}

variable "grant_artifact_registry" {
  type        = bool
  description = "Grant the Artifact Registry service agent (service-<num>@gcp-sa-artifactregistry) encrypterDecrypter on the key. The registry itself lives in the artifact_registry component, which references this same key by its deterministic resource path."
  default     = true
}

variable "grant_secretmanager" {
  type        = bool
  description = "Grant the Secret Manager service agent (service-<num>@gcp-sa-secretmanager) encrypterDecrypter on the key. Secret Manager applies CMEK per user-managed replica, so the key must be in the same region as every secret replica."
  default     = true
}

variable "grant_gke" {
  type        = bool
  description = "Grant the GKE service agent (service-<num>@container-engine-robot) encrypterDecrypter on the key, so the cluster can use it for application-layer Secrets encryption of etcd. The key must be in the cluster's region."
  default     = false
}

variable "project_number" {
  type        = string
  description = "Numeric project number, used to build the GKE service-agent email for grant_gke. Only required when grant_gke = true."
  default     = ""

  validation {
    condition     = !var.grant_gke || can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be the numeric project number when grant_gke = true."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the crypto key."
  default     = {}
}

variable "adopt_existing" {
  type        = bool
  description = "Import the same-named key ring and crypto key already present in the project into state instead of creating them. Cloud KMS objects are never deletable, so any re-bootstrap of an existing project needs this on. No-op once both are in state."
  default     = false
}
