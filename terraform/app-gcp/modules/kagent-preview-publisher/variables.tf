variable "enabled" {
  type        = bool
  description = "Materialize the Terraform-owned Cloud Build and Artifact Registry rail for kagent fork previews."
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

variable "github_remote_uri" {
  type        = string
  description = "Read-only HTTPS source URL for the reviewed kagent fork."

  validation {
    condition     = var.github_remote_uri == "https://github.com/pilprod/kagent.git"
    error_message = "The kagent preview publisher accepts only the reviewed pilprod/kagent fork."
  }
}

variable "source_commit" {
  type        = string
  description = "Exact reviewed kagent fork commit accepted by the manual release trigger."

  validation {
    condition     = !var.enabled || can(regex("^[0-9a-f]{40}$", var.source_commit))
    error_message = "An enabled publisher requires an exact lowercase 40-character source_commit."
  }
}

variable "release_tag_regex" {
  type        = string
  description = "Immutable fork-preview tag family accepted by the manual Cloud Build trigger. The gcp-v prefix deliberately avoids the fork's legacy GitHub Actions tag glob."
  default     = "^gcp-v[0-9]+\\.[0-9]+\\.[0-9]+-external-slot\\.kap\\.[0-9]+$"

  validation {
    condition = (
      startswith(var.release_tag_regex, "^gcp-v") &&
      endswith(var.release_tag_regex, "$") &&
      !strcontains(var.release_tag_regex, "'") &&
      !strcontains(var.release_tag_regex, "\n") &&
      !strcontains(var.release_tag_regex, "\r")
    )
    error_message = "release_tag_regex must be an anchored gcp-v-prefixed regular expression."
  }
}

variable "artifact_registry_location" {
  type        = string
  description = "Location of the existing platform-owned Artifact Registry repository."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Dedicated private immutable platform-owned Artifact Registry repository receiving only passing kagent preview images and charts."
}

variable "staging_registry_repository_id" {
  type        = string
  description = "Dedicated private platform-owned Artifact Registry repository receiving disposable kagent candidate images before scan and promotion."
}

variable "build_timeout" {
  type        = string
  description = "Maximum Cloud Build duration for multi-architecture images, chart verification and scanning."
  default     = "7200s"
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
  description = "Deprecated empty GHCR Secret Manager container retained for a non-destructive migration. The Artifact Registry trigger never reads it and no version is Terraform-managed."
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
