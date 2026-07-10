variable "project_id" {
  type        = string
  description = "Existing GCP project ID the platform is deployed into."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project ID (6-30 chars, lowercase letters, digits, hyphens)."
  }
}

variable "activate_apis" {
  type        = list(string)
  description = "APIs to enable on the project."

  validation {
    condition     = alltrue([for a in var.activate_apis : can(regex("^[a-z0-9.-]+\\.googleapis\\.com$", a))])
    error_message = "Each API must be a fully-qualified *.googleapis.com service name."
  }
}

variable "disable_services_on_destroy" {
  type        = bool
  description = "Whether to disable the APIs when this module is destroyed. Keep false in shared projects."
  default     = false
}

variable "disable_dependent_services" {
  type        = bool
  description = "Whether to also disable services that depend on the ones listed when disabling."
  default     = false
}
