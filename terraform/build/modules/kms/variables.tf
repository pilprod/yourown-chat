variable "project_id" {
  type        = string
  description = "Project the key ring and key are created in."
}

variable "location" {
  type        = string
  description = "KMS location. Must match the region of every CMEK consumer -- here the github-pat secret's user-managed replica (e.g. 'europe-west3'). Also used as the keyring name prefix."
}

variable "key_name" {
  type        = string
  description = "Short name of the crypto key that wraps the github-pat secret DEK."
  default     = "github-pat"
}

variable "protection_level" {
  type        = string
  description = "Key protection level. HSM = FIPS 140-2 Level 3 hardware custody (~$1.00/active version/mo); SOFTWARE = Level 1 (~$0.06). Immutable once the key is created. Defaults to SOFTWARE -- a single PAT-wrapping key does not need HSM custody."
  default     = "SOFTWARE"

  validation {
    condition     = contains(["HSM", "SOFTWARE"], var.protection_level)
    error_message = "protection_level must be HSM or SOFTWARE."
  }
}

variable "rotation_period" {
  type        = string
  description = "Automatic rotation period for the symmetric key, in seconds with an 's' suffix (KMS minimum is 24h). Default is 90 days."
  default     = "7776000s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.rotation_period))
    error_message = "rotation_period must be a number of seconds with an 's' suffix, e.g. '7776000s'."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the crypto key."
  default     = {}
}
