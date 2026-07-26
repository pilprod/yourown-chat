variable "project_id" {
  type        = string
  description = "Project where the Secret Manager secret is created."
}

variable "secret_id" {
  type        = string
  description = "Secret Manager secret ID."
}

variable "secret_data" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Write-only secret payload. It is sent to Google and never persisted in Terraform state."
}

variable "secret_data_version" {
  type        = number
  description = "Operator-controlled write-only value version. Increment when secret_data rotates."

  validation {
    condition     = var.secret_data_version >= 1 && floor(var.secret_data_version) == var.secret_data_version
    error_message = "secret_data_version must be a positive integer."
  }
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
