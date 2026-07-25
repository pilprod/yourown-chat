variable "project_id" {
  type        = string
  description = "Google Cloud project containing Agent Registry."
}

variable "location" {
  type        = string
  description = "Supported Agent Registry region."
}

variable "endpoints" {
  type = map(object({
    display_name     = string
    description      = string
    url              = string
    protocol_binding = optional(string, "HTTP_JSON")
  }))
}

variable "external_mcp_servers" {
  type = map(object({
    display_name     = string
    description      = string
    url              = string
    protocol_binding = optional(string, "JSONRPC")
  }))
}
