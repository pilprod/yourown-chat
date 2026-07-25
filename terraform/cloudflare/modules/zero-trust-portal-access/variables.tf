variable "account_id" {
  type        = string
  description = "Cloudflare account that owns the explicitly managed Portal Access application."
}

variable "hostname" {
  type        = string
  description = "MCP Portal hostname secured by this type=mcp_portal Access application."
}

variable "allowed_emails" {
  type        = list(string)
  description = "Emails allowed to authenticate to the MCP Portal."

  validation {
    condition     = length(var.allowed_emails) > 0
    error_message = "Provide at least one allowed email -- an empty include list would lock everyone out."
  }
}
