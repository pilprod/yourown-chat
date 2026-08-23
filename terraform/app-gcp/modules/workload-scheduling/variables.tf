variable "dev_namespace" {
  type        = string
  description = "Namespace receiving the disposable-workload compute quota and default container limits."
  default     = "dev"
}

variable "agent_namespace" {
  type        = string
  description = "Namespace containing the agent pilot and its narrow verification service account."
  default     = "yourown-agents"
}

variable "agent_enabled" {
  type        = bool
  description = "Create verifier RBAC only when the agent pilot namespace exists."
  default     = false
}

variable "kagent_testbed_enabled" {
  type        = bool
  description = "Apply quotas and network isolation because the legacy Terraform-owned M0 testbed is enabled."
  default     = false
}

variable "kagent_preview_enabled" {
  type        = bool
  description = "Apply quotas and network isolation because the Cloud Deploy API v2 preview path is prepared."
  default     = false
}

variable "kagent_preview_ui_access_enabled" {
  type        = bool
  description = "Admit only the existing mcp-tunnel cloudflared pod to the kagent preview UI on port 8080 after the Cloudflare Access route is ready."
  default     = false

  validation {
    condition     = !var.kagent_preview_ui_access_enabled || var.kagent_preview_enabled
    error_message = "kagent_preview_ui_access_enabled requires kagent_preview_enabled."
  }
}

variable "kagent_system_namespace" {
  type        = string
  description = "Namespace containing the kagent controller and bundled database."
  default     = "kagent-system"
}

variable "kagent_testbed_namespace" {
  type        = string
  description = "Namespace containing test agents and deterministic fixtures."
  default     = "kagent-testbed"
}

variable "kagent_preview_execution_service_account_email" {
  type        = string
  description = "Cloud Deploy preview execution GSA bound as a Kubernetes User to the narrow namespaced RBAC-authoring Role."
  default     = ""

  validation {
    condition     = var.kagent_preview_execution_service_account_email == "" || can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.kagent_preview_execution_service_account_email))
    error_message = "kagent_preview_execution_service_account_email must be a Google service-account email."
  }
}

variable "kagent_preview_controller_service_account" {
  type        = string
  description = "ServiceAccount name produced by the locked kagent preview fullnameOverride."
  default     = "kagent-preview-controller"
}

variable "kagent_preview_ate_api_service_account" {
  type = object({
    namespace = string
    name      = string
  })
  description = "Externally managed Substrate ate-api identity allowed to read controller-provided environment sources in the two preview namespaces."
  default = {
    namespace = "ate-system"
    name      = "ate-api-server"
  }
}

variable "server_namespaces" {
  type        = set(string)
  description = "Trust-zone namespaces containing the independent YourOwn.Chat server plane."
  default     = ["edge", "identity", "control"]
}

variable "server_enabled" {
  type        = bool
  description = "Create the small server-plane quota and default container limits."
  default     = false
}

variable "mcp_dev_deployments" {
  type        = set(string)
  description = "Ephemeral MCP Deployments in the dev namespace that the Cloud Deploy cleanup identity may scale to zero."
  default = [
    "dev-mcp-terraform-stacks",
    "dev-mcp-google-cloud",
  ]
}

variable "cleanup_service_account_emails" {
  type = object({
    mattermost = string
    mcp        = string
  })
  description = "Dedicated Cloud Deploy PREDEPLOY service-account emails granted narrowly scoped Kubernetes cleanup access."
}

variable "cleanup_kubernetes_service_account" {
  type = object({
    namespace = string
    name      = string
  })
  description = "Production Google Cloud MCP KSA allowed to inspect and scale only the exact disposable dev Deployments governed by the cleanup Roles."
  default = {
    namespace = "mcp-google-cloud"
    name      = "mcp-servers"
  }
}
