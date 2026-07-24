variable "dev_namespace" {
  type        = string
  description = "Namespace receiving the disposable-workload compute quota and default container limits."
  default     = "dev"
}

variable "mcp_dev_deployments" {
  type        = map(string)
  description = "Namespace => ephemeral MCP Deployment that the post-deploy cleanup identity may scale to zero."
  default = {
    mcp-terraform        = "dev-mcp-terraform"
    mcp-google-cloud     = "dev-mcp-google-cloud"
    mcp-google-workspace = "dev-mcp-google-workspace"
  }
}

variable "mcp_cleanup_service_account_namespace" {
  type        = string
  description = "Namespace containing the cross-namespace MCP cleanup ServiceAccount."
  default     = "mcp-tunnel"
}

variable "kubernetes_api_endpoint" {
  type        = string
  description = "Private GKE control-plane IPv4 address used as the backend of the in-cluster kubernetes Service."

  validation {
    condition     = can(cidrhost("${var.kubernetes_api_endpoint}/32", 0))
    error_message = "kubernetes_api_endpoint must be an IPv4 address."
  }
}
