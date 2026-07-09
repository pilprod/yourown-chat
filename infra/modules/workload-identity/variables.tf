variable "project_id" {
  type        = string
  description = "Project that owns the Google service account."

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "account_id" {
  type        = string
  description = "Google service account ID (the part before @). 6-30 chars, lowercase/digits/hyphen."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.account_id))
    error_message = "account_id must be 6-30 chars: start with a letter, then lowercase letters, digits or hyphens."
  }
}

variable "display_name" {
  type        = string
  description = "Human-friendly display name for the service account."
  default     = ""
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace of the KSA to bind."
}

variable "ksa_name" {
  type        = string
  description = "Kubernetes service account name to bind via Workload Identity."
}

variable "project_roles" {
  type        = list(string)
  description = "Optional project-level IAM roles to grant the GSA (least privilege — keep short)."
  default     = []
}
