variable "terraform_mcp_server_enabled" {
  type        = bool
  description = "Append the terraform-mcp-server Skaffold profile to the prod Cloud Deploy stage."
  default     = true
}
