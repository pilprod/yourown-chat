variable "project_id" {
  type        = string
  description = "Google Cloud project containing Agent Registry."
}

variable "region" {
  type        = string
  description = "Agent Registry location. Must be a supported region, not the eu/us multi-region."
  default     = "europe-west3"
}

variable "identity_token" {
  type        = string
  ephemeral   = true
  description = "HCP Terraform OIDC JWT, minted per run and never stored in state."
}

variable "audience" {
  type        = string
  description = "Workload Identity Federation provider resource name."
}

variable "service_account_email" {
  type        = string
  description = "GCP apply service account impersonated through Workload Identity Federation."
}

variable "endpoints" {
  type = map(object({
    display_name     = string
    description      = string
    url              = string
    protocol_binding = optional(string, "HTTP_JSON")
  }))
  description = "External REST/RPC destinations used by agents and governed through Agent Registry."
  default     = {}

  validation {
    condition = alltrue([
      for endpoint in values(var.endpoints) :
      contains(["HTTP_JSON", "GRPC", "JSONRPC"], endpoint.protocol_binding)
    ])
    error_message = "Endpoint protocol_binding must be HTTP_JSON, GRPC, or JSONRPC."
  }
}

variable "external_mcp_servers" {
  type = map(object({
    display_name     = string
    description      = string
    url              = string
    protocol_binding = optional(string, "JSONRPC")
  }))
  description = "Vendor-hosted MCP endpoints to register without duplicating GKE or Google auto-discovered servers."
  default     = {}

  validation {
    condition = alltrue([
      for server in values(var.external_mcp_servers) :
      contains(["HTTP_JSON", "GRPC", "JSONRPC"], server.protocol_binding)
    ])
    error_message = "MCP protocol_binding must be HTTP_JSON, GRPC, or JSONRPC."
  }
}
