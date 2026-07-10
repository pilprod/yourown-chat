variable "project_id" {
  type        = string
  description = "Project the bucket is created in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for the bucket name, e.g. 'yourown-chat-dev-app'."
}

variable "location" {
  type        = string
  description = "Bucket location. Use a region (e.g. EUROPE-WEST3) to keep data in Germany."
  default     = "EUROPE-WEST3"
}

variable "storage_class" {
  type        = string
  description = "Default storage class."
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "NEARLINE", "COLDLINE", "ARCHIVE"], var.storage_class)
    error_message = "storage_class must be STANDARD, NEARLINE, COLDLINE or ARCHIVE."
  }
}

variable "versioning_enabled" {
  type        = bool
  description = "Enable object versioning."
  default     = true
}

variable "public_access_prevention" {
  type        = string
  description = "Public access prevention setting."
  default     = "enforced"

  validation {
    condition     = contains(["enforced", "inherited"], var.public_access_prevention)
    error_message = "public_access_prevention must be enforced or inherited."
  }
}

variable "force_destroy" {
  type        = bool
  description = "Allow Terraform to delete a non-empty bucket. Keep false outside dev."
  default     = false
}

variable "kms_key_name" {
  type        = string
  description = "Optional CMEK key for default encryption. Null = Google-managed keys."
  default     = null
}

variable "lifecycle_rules" {
  type = list(object({
    action_type           = string           # Delete | SetStorageClass | AbortIncompleteMultipartUpload
    action_storage_class  = optional(string) # required when action_type = SetStorageClass
    age                   = optional(number)
    num_newer_versions    = optional(number)
    days_since_noncurrent = optional(number)
    with_state            = optional(string) # LIVE | ARCHIVED | ANY
  }))
  description = "Object lifecycle rules."
  default     = []
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the bucket."
  default     = {}
}

# --- Optional S3-compatible (HMAC) credentials for Mattermost filestore ------
variable "create_filestore_hmac" {
  type        = bool
  description = "Create a dedicated SA + HMAC key with objectAdmin on this bucket, and store the S3-compatible access/secret keys in Secret Manager. Used by Mattermost's S3 filestore driver against the GCS interoperability endpoint."
  default     = false
}

variable "filestore_secret_accessors" {
  type        = list(string)
  description = "IAM members granted secretAccessor on the filestore access/secret key secrets (e.g. the Mattermost Workload Identity SA)."
  default     = []
}

variable "secret_replica_locations" {
  type        = list(string)
  description = "Regions the filestore secrets are replicated to (keep data in-region)."
  default     = ["europe-west3"]
}
