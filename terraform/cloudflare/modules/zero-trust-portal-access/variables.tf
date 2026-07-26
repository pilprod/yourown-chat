variable "account_id" {
  type        = string
  description = "Cloudflare account that owns the explicitly managed Portal Access application."
}

variable "hostname" {
  type        = string
  description = "MCP Portal hostname secured by this type=mcp_portal Access application."
}

variable "service_token_id" {
  type        = string
  description = "Access service-token ID used only by the OAuth compatibility Worker to reach the Portal origin."
}
