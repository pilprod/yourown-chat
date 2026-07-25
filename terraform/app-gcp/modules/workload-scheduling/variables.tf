variable "dev_namespace" {
  type        = string
  description = "Namespace receiving the disposable-workload compute quota and default container limits."
  default     = "dev"
}

variable "mcp_dev_deployments" {
  type        = set(string)
  description = "Ephemeral MCP Deployments in the dev namespace that the Cloud Deploy cleanup identity may scale to zero."
  default = [
    "dev-mcp-terraform",
    "dev-mcp-terraform-stacks",
    "dev-mcp-google-cloud",
    "dev-mcp-whatsapp-business",
  ]
}

variable "cleanup_service_account_emails" {
  type = object({
    mattermost = string
    mcp        = string
  })
  description = "Dedicated Cloud Deploy PREDEPLOY service-account emails granted narrowly scoped Kubernetes cleanup access."
}
