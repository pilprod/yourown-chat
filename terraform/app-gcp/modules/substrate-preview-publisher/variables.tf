variable "enabled" {
  type        = bool
  description = "Materialize the private Artifact Registry publication rail for the reviewed Substrate release."
  default     = false
}

variable "evidence_bucket_owner_enabled" {
  type        = bool
  description = "Whether the kagent publisher component that owns the shared evidence bucket is enabled."
  default     = false
}

variable "project_id" {
  type        = string
  description = "GCP project owning the private release rail."

  validation {
    condition     = var.project_id == "yourown-chat"
    error_message = "The reviewed private Substrate rail is restricted to project yourown-chat."
  }
}

variable "region" {
  type        = string
  description = "Cloud Build region."

  validation {
    condition     = var.region == "europe-west3"
    error_message = "The reviewed private Substrate rail is restricted to europe-west3."
  }
}

variable "github_remote_uri" {
  type        = string
  description = "Read-only HTTPS source URL for the reviewed Substrate fork."

  validation {
    condition     = var.github_remote_uri == "https://github.com/pilprod/substrate.git"
    error_message = "The private Substrate publisher accepts only the reviewed pilprod/substrate fork."
  }
}

variable "source_tag" {
  type        = string
  description = "Exact annotated Substrate source tag accepted by the publisher."
  default     = "v0.0.22"

  validation {
    condition     = var.source_tag == "v0.0.22"
    error_message = "The initial private Substrate handoff is pinned to source tag v0.0.22."
  }
}

variable "source_commit" {
  type        = string
  description = "Exact peeled commit of the reviewed annotated Substrate source tag."
  default     = "e9ed68e587b56df2aa2a7f0267a744598c4d48b4"

  validation {
    condition     = var.source_commit == "e9ed68e587b56df2aa2a7f0267a744598c4d48b4"
    error_message = "The initial private Substrate handoff is pinned to commit e9ed68e587b56df2aa2a7f0267a744598c4d48b4."
  }
}

variable "source_tag_object" {
  type        = string
  description = "Exact annotated tag object proving the reviewed v0.0.22 source coordinate."
  default     = "00a6a684cea3b3feea67461cf79347332ec759ef"

  validation {
    condition     = var.source_tag_object == "00a6a684cea3b3feea67461cf79347332ec759ef"
    error_message = "The reviewed v0.0.22 annotated tag object is 00a6a684cea3b3feea67461cf79347332ec759ef."
  }
}

variable "release_version" {
  type        = string
  description = "One exact private GAR release coordinate authorized by the applied configuration. A failed locked publication requires a reviewed input bump."
  default     = "0.0.22-private.1"

  validation {
    condition     = var.release_version == "0.0.22-private.1"
    error_message = "The initial private Substrate handoff is pinned to release coordinate 0.0.22-private.1."
  }
}

variable "artifact_registry_location" {
  type        = string
  description = "Location of the existing private immutable repository."

  validation {
    condition     = var.artifact_registry_location == "europe-west3"
    error_message = "Substrate private artifacts must remain in europe-west3."
  }
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Existing private immutable Artifact Registry repository."

  validation {
    condition     = var.artifact_registry_repository_id == "kagent-preview"
    error_message = "Substrate final artifacts must use the existing private kagent-preview repository."
  }
}

variable "staging_registry_repository_id" {
  type        = string
  description = "Existing private disposable candidate Artifact Registry repository."

  validation {
    condition     = var.staging_registry_repository_id == "kagent-staging"
    error_message = "Substrate candidates must use the existing private kagent-staging repository."
  }
}

variable "evidence_bucket_name" {
  type        = string
  description = "Existing private versioned bucket retaining kagent and Substrate release evidence."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.evidence_bucket_name))
    error_message = "evidence_bucket_name must be a valid 3-63 character GCS bucket name."
  }
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply identity managing the Pub/Sub topic and allowed to submit release requests."

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.iam\\.gserviceaccount\\.com$", var.apply_service_account_email))
    error_message = "apply_service_account_email must be a Google service-account email."
  }
}

variable "submitter_members" {
  type        = set(string)
  description = "Additional explicit IAM members allowed to publish to the release-request topic."
  default     = []

  validation {
    condition = alltrue([
      for member in var.submitter_members :
      can(regex("^(user|group|serviceAccount):[^[:space:]]+$", member))
    ])
    error_message = "submitter_members must contain explicit user:, group:, or serviceAccount: IAM members."
  }
}

variable "build_timeout" {
  type        = string
  description = "Maximum Cloud Build duration for source verification, multi-architecture builds, scans and promotion."
  default     = "7200s"
}
