variable "enabled" {
  type        = bool
  description = "Opt-in gate for the cluster-wide Gateway API and official agentgateway control plane."
  default     = false
}

variable "namespace" {
  type        = string
  description = "Namespace owned by the official agentgateway control plane."
  default     = "agentgateway-system"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid Kubernetes DNS label."
  }
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the Terraform-owned namespace."
  default     = {}
}
