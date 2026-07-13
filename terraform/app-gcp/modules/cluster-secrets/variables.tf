variable "namespaces" {
  type = map(object({
    labels = optional(map(string), {})
  }))
  description = "Tenant namespaces to create (map keyed by namespace name). Terraform owns these so credential Secrets can be created before Cloud Deploy deploys workloads into them."
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
