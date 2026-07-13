variable "project_id" {
  type        = string
  description = "Project the secrets are created in."
}

variable "replica_locations" {
  type        = list(string)
  description = "Regions to replicate each secret to (user-managed replication keeps data in-region)."
  default     = ["europe-west3"]

  validation {
    condition     = length(var.replica_locations) > 0
    error_message = "Provide at least one replica location."
  }
}

variable "secrets" {
  type = map(object({
    # How the value is provisioned:
    #   generate = true            -> Terraform creates a random value + version
    #   value    = "..."           -> use the provided value as the version
    #   neither                    -> create an empty secret to be populated out-of-band
    generate  = optional(bool, false)
    length    = optional(number, 32)
    value     = optional(string)
    accessors = optional(list(string), [])
    # Include special characters in a generated value. Set false for values
    # embedded in URLs/DSNs (e.g. a Postgres password used in postgres://...),
    # where characters like @ : / would corrupt the connection string.
    special = optional(bool, true)
  }))
  description = "Map of logical secret name => spec. Accessors are IAM members granted secretAccessor on that secret."
  default     = {}
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every secret."
  default     = {}
}

variable "kms_key_name" {
  type        = string
  description = "Optional CMEK key for Secret Manager. When set, every secret replica is encrypted with this customer-managed key (which must live in the same region as each replica). Null = Google-managed encryption."
  default     = null
}
