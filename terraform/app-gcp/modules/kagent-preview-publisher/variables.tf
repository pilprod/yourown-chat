variable "enabled" {
  type        = bool
  description = "Materialize the dedicated kagent fork preview publication identity, evidence bucket and empty GHCR credential container."
  default     = false
}

variable "project_id" {
  type        = string
  description = "GCP project that owns the preview publisher resources."
}

variable "region" {
  type        = string
  description = "Region for the evidence bucket and Secret Manager replica."
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply identity granted actAs on only the dedicated publisher service account."

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", var.apply_service_account_email))
    error_message = "apply_service_account_email must be a Google service-account email."
  }
}

variable "submitter_members" {
  type        = set(string)
  description = "Additional explicit IAM members allowed to submit a build as the publisher service account. The Terraform apply SA is added automatically."
  default     = []

  validation {
    condition = alltrue([
      for member in var.submitter_members :
      can(regex("^(user|group|serviceAccount):[^[:space:]]+$", member))
    ])
    error_message = "submitter_members must contain explicit user:, group:, or serviceAccount: IAM members."
  }
}

variable "evidence_bucket_name" {
  type        = string
  description = "Globally unique private bucket for immutable build receipts."
  default     = "disabled-kagent-preview-evidence"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.evidence_bucket_name))
    error_message = "evidence_bucket_name must be a valid 3-63 character GCS bucket name."
  }
}

variable "evidence_retention_seconds" {
  type        = number
  description = "Minimum retention applied to release evidence objects. Defaults to one year."
  default     = 31536000

  validation {
    condition     = var.evidence_retention_seconds >= 86400
    error_message = "evidence_retention_seconds must retain evidence for at least one day."
  }
}

variable "ghcr_secret_id" {
  type        = string
  description = "Secret Manager container name for the dedicated minimal GHCR write token. No version is Terraform-managed."
  default     = "kagent-ghcr-write"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,255}$", var.ghcr_secret_id))
    error_message = "ghcr_secret_id must be a valid Secret Manager secret ID."
  }
}

variable "kms_key_name" {
  type        = string
  description = "Optional shared CMEK key for the evidence bucket and Secret Manager replica."
  default     = null
  nullable    = true
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the evidence bucket and secret container."
  default     = {}
}
