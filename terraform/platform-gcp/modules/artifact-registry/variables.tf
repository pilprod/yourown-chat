variable "project_id" {
  type        = string
  description = "Project the repository is created in."
}

variable "location" {
  type        = string
  description = "Region for the Artifact Registry repository (keep close to GKE)."
}

variable "repository_id" {
  type        = string
  description = "Repository ID (name)."
  default     = "containers"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,62}$", var.repository_id))
    error_message = "repository_id must be lowercase alphanumeric/hyphen, starting with a letter."
  }
}

variable "description" {
  type        = string
  description = "Repository description."
  default     = "Container images built by CI/CD."
}

variable "immutable_tags" {
  type        = bool
  description = "Prevent tags from being overwritten (recommended for traceable releases)."
  default     = false
}

variable "kms_key_name" {
  type        = string
  description = "Optional CMEK key for the repository. Null = Google-managed keys."
  default     = null
}

variable "keep_untagged_days" {
  type        = number
  description = "Delete untagged images older than this many days (0 disables the policy)."
  default     = 14
}

variable "keep_recent_versions" {
  type        = number
  description = "Always keep at least this many most-recent versions."
  default     = 10
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the repository."
  default     = {}
}

variable "vulnerability_scanning" {
  type        = bool
  description = "Automatically scan images pushed to this repository for vulnerabilities (Artifact Analysis). Requires the containerscanning API on the project. Paid: ~$0.26 per scanned image digest."
  default     = false
}
