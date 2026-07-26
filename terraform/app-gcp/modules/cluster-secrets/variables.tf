variable "namespaces" {
  type = map(object({
    labels = optional(map(string), {})
  }))
  description = "Tenant namespaces to create (map keyed by namespace name). Terraform owns these so credential Secrets can be created before Cloud Deploy deploys workloads into them."
}

variable "adopt_existing_namespaces" {
  type        = bool
  description = "Import namespaces that already exist in the cluster (e.g. created out-of-band by a prior Cloud Deploy namespaces.yaml) into Terraform state instead of failing with 'already exists'. Set true for the one-time adoption apply, then back to false (importing a non-existent namespace on a fresh cluster fails)."
  default     = false
}

variable "secrets" {
  type = map(object({
    name      = string
    namespace = string
    type      = optional(string, "Opaque")
    labels    = optional(map(string), {})
    data      = map(string)
  }))
  description = "Credential Secrets to create. `data` values are plaintext (the provider base64-encodes them). Sensitive."
  sensitive   = true
}

variable "storage_classes" {
  type = map(object({
    provisioner            = string
    parameters             = optional(map(string), {})
    reclaim_policy         = optional(string, "Delete")
    volume_binding_mode    = optional(string, "WaitForFirstConsumer")
    allow_volume_expansion = optional(bool, true)
  }))
  description = "Storage classes required by sensitive stateful workloads."
  default     = {}
}
