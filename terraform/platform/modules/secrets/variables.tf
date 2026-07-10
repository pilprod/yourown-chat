variable "project_id" {
  type        = string
  description = "Project the secrets are created in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for secret IDs, e.g. 'yourown-chat'."
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
  }))
  description = "Map of logical secret name => spec. Accessors are IAM members granted secretAccessor on that secret."
  default     = {}
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every secret."
  default     = {}
}
