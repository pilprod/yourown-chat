variable "project_id" {
  type        = string
  description = "Project that owns the kagent preview repository link, trigger, build identity and delivery pipeline."
}

variable "region" {
  type        = string
  description = "Region shared by Cloud Build, Cloud Deploy and Artifact Registry."
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply identity. It receives actAs only on the dedicated kagent preview build identity so Terraform can create the trigger."
}

variable "connection_name" {
  type        = string
  description = "Existing Cloud Build v2 GitHub connection authorized out of band."
  default     = "pilprod-github"
}

variable "repository_name" {
  type        = string
  description = "Cloud Build v2 repository resource name for the kagent integration/release repository."
  default     = "yourown-chat-kagent"
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the repository that owns cloudbuild.preview.yaml and the preview release contract."
  default     = "https://github.com/pilprod/yourown-chat-kagent.git"

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.github_remote_uri))
    error_message = "github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "preview_tag_regex" {
  type        = string
  description = "Anchored regex for immutable kagent integration-repository tags. No branch trigger is created."

  validation {
    condition     = startswith(var.preview_tag_regex, "^") && endswith(var.preview_tag_regex, "$")
    error_message = "preview_tag_regex must be anchored with ^ and $."
  }
}

variable "cloudbuild_config_path" {
  type        = string
  description = "Repository-root Cloud Build configuration used by the immutable preview-tag trigger."
  default     = "cloudbuild.preview.yaml"

  validation {
    condition     = var.cloudbuild_config_path == "cloudbuild.preview.yaml"
    error_message = "The kagent preview trigger must use the repository-root cloudbuild.preview.yaml contract."
  }
}

variable "preview_lock_path" {
  type        = string
  description = "Repository-relative lock that selects the exact remotely reachable fork commit."
  default     = "locks/kagent-preview.lock.json"

  validation {
    condition     = var.preview_lock_path == "locks/kagent-preview.lock.json"
    error_message = "The preview pipeline contract requires locks/kagent-preview.lock.json."
  }
}

variable "crds_ready" {
  type        = bool
  description = "Whether a platform admin has applied and verified the exact current-main CRD bundle. False blocks release creation inside cloudbuild.preview.yaml."
  default     = false

  validation {
    condition     = !var.crds_ready || can(regex("^[0-9a-f]{64}$", var.crd_bundle_sha256))
    error_message = "crds_ready=true requires an exact 64-character SHA-256 CRD bundle digest."
  }
}

variable "crd_bundle_sha256" {
  type        = string
  description = "Exact raw SHA-256 digest of the platform-admin-applied current-main CRD bundle."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.crd_bundle_sha256))
    error_message = "crd_bundle_sha256 must be exactly 64 lowercase hexadecimal characters."
  }
}

variable "substrate_ready" {
  type        = bool
  description = "Whether GKE beta APIs, the node rollout, external Substrate and its kagent WorkerPool were applied and health-checked."
  default     = false
}

variable "substrate_version" {
  type        = string
  description = "Expected external Substrate version selected by the locked preview runtime contract."
  default     = "0.0.20"

  validation {
    condition     = var.substrate_version == "0.0.20"
    error_message = "The reviewed preview runtime contract currently requires Substrate 0.0.20."
  }
}

variable "artifact_registry_location" {
  type        = string
  description = "Artifact Registry location containing the shared Docker repository."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry Docker repository receiving the attested kagent controller image."
}

variable "delivery_pipeline_name" {
  type        = string
  description = "Name of the testbed-only Cloud Deploy pipeline."
}

variable "initial_target_name" {
  type        = string
  description = "Only valid destination for a preview release. Passed to the build as an explicit structural bound."
}

variable "execution_service_account_email" {
  type        = string
  description = "Cloud Deploy execution identity for the testbed target. The build identity receives actAs only on this account."
}

variable "source_bucket_kms_key_name" {
  type        = string
  description = "Optional CMEK key for frozen release sources and qualification evidence."
  default     = null
}

variable "source_retention_days" {
  type        = number
  description = "Retention in days for frozen release-source archives and preview evidence."
  default     = 30

  validation {
    condition     = var.source_retention_days >= 1
    error_message = "source_retention_days must be at least one day."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the dedicated preview source/evidence bucket."
  default     = {}
}
