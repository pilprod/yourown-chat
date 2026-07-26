variable "project_id" {
  type        = string
  description = "Project where the Secret Manager secret is created."
}

variable "secret_id" {
  type        = string
  description = "Secret Manager secret ID."
}

variable "adopt_existing" {
  type        = bool
  description = "Import a secret created during the one-time write-only bootstrap."
  default     = false
}

variable "replica_locations" {
  type        = list(string)
  description = "User-managed Secret Manager replica locations."

  validation {
    condition     = length(var.replica_locations) > 0
    error_message = "Provide at least one replica location."
  }
}

variable "kms_key_name" {
  type        = string
  description = "Optional CMEK key for Secret Manager."
  default     = null
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the secret."
  default     = {}
}

variable "accessors" {
  type        = list(string)
  description = "IAM members granted access to this secret only."
  default     = []
}
