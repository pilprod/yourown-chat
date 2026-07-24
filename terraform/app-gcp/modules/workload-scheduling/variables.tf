variable "dev_namespace" {
  type        = string
  description = "Namespace receiving the disposable-workload compute quota and default container limits."
  default     = "dev"
}

variable "mcp_dev_deployments" {
  type        = map(string)
  description = "Namespace => ephemeral MCP Deployment that the Cloud Deploy cleanup identity may scale to zero."
  default = {
    mcp-terraform        = "dev-mcp-terraform"
    mcp-google-cloud     = "dev-mcp-google-cloud"
    mcp-google-workspace = "dev-mcp-google-workspace"
  }
}

variable "cleanup_service_account_emails" {
  type = object({
    mattermost = string
    mcp        = string
  })
  description = "Dedicated Cloud Deploy PREDEPLOY service-account emails granted narrowly scoped Kubernetes cleanup access."
}
