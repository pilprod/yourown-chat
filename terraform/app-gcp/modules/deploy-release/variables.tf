variable "project_id" {
  type        = string
  description = "Project the Cloud Build connection, repository, trigger, releaser identity and source-staging bucket live in."
}

variable "region" {
  type        = string
  description = "Region for the 2nd-gen connection/repository/trigger, the source-staging bucket and the (regional) Cloud Deploy pipeline this releaser targets."
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply SA (the impersonated identity). Granted actAs on the releaser SA so it can create a trigger that runs as that least-privilege identity."
}

# --- GitHub source: THIS repo (holds helm/, the Skaffold render root) --------
# Every repository name and clone URL below is supplied by the private service
# catalog through the component inputs; the public module has no defaults.
variable "connection_name" {
  type        = string
  description = "Name of the EXISTING Cloud Build 2nd-gen GitHub connection (authorized once in the console via OAuth, see README.md) the deploy repo is linked to. Shared with the image CI; Terraform never creates or manages the connection."
}

variable "repository_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen repository resource linking the connection to the deploy source repo (catalog role deploy)."
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the deploy source repository (the one holding helm/; catalog role deploy)."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.github_remote_uri))
    error_message = "github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "rtcd_repository_name" {
  type        = string
  description = "Cloud Build repository resource name for the RTCD source (catalog role rtcd)."
}

variable "rtcd_github_remote_uri" {
  type        = string
  description = "HTTPS GitHub URL of the RTCD source repository (catalog role rtcd)."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.rtcd_github_remote_uri))
    error_message = "rtcd_github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "rtcd_release_tag_regex" {
  type        = string
  description = "Immutable patched-fork RTCD source tags allowed to build audited release images."
  default     = "^v[0-9]+\\.[0-9]+\\.[0-9]+-patched$"
}

variable "backend_repository_name" {
  type        = string
  description = "Cloud Build repository resource for the product backend source (catalog role backend)."
}

variable "backend_github_remote_uri" {
  type        = string
  description = "HTTPS GitHub URL of the product backend source repository (catalog role backend)."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.backend_github_remote_uri))
    error_message = "backend_github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "mcp_repository_name" {
  type        = string
  description = "Cloud Build repository resource for the private first-party MCP server source (catalog role mcp)."
}

variable "mcp_github_remote_uri" {
  type        = string
  description = "HTTPS GitHub URL of the private first-party MCP server source repository (catalog role mcp)."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.mcp_github_remote_uri))
    error_message = "mcp_github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "mcp_branch_regex" {
  type        = string
  description = "Reviewed MCP branch built, tested and scanned without deployment."
  default     = "^main$"
}

variable "mcp_release_tag_regex" {
  type        = string
  description = "Immutable MCP source tags allowed into the approval-gated MCP pipeline."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "backend_branch_regex" {
  type        = string
  description = "Reviewed backend branch built and scanned in GCP without deployment."
  default     = "^main$"
}

variable "backend_release_tag_regex" {
  type        = string
  description = "Immutable server source tags that publish the control API image."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "backend_image_prefix" {
  type        = string
  description = "Artifact Registry prefix for the client-facing control API image."
  default     = "yourown-chat"
}

# --- Cloud Deploy target (from the clouddeploy component) --------------------
variable "delivery_pipelines" {
  type = map(object({
    execution_service_account_email = string
  }))
  description = "Component pipeline name => execution identity. The platform tag router creates releases only for components changed since the previous release tag."
}

variable "mcp_enabled" {
  type        = bool
  description = "Whether the unified platform tag router may create MCP releases. Mattermost routing remains enabled independently."
}

variable "server_enabled" {
  type        = bool
  description = "Whether a backend tag may create the independent server-plane release."
  default     = false
}

variable "kagent_substrate_delivery" {
  type        = any
  description = "Validated immutable dual-artifact testbed contract forwarded to the stdlib-only release renderer."
  default = {
    bootstrap_enabled = false
    release_enabled   = false
  }
}

variable "kagent_substrate_prerequisites_ready" {
  type        = bool
  description = "Fail-closed gate covering retained ownership handoff, CRDs, native Secrets, agentgateway and the dedicated public IP."
  default     = false
}

variable "mattermost_image_repository" {
  type = object({
    location      = string
    repository_id = string
    image_name    = string
  })
  description = "Artifact Registry coordinates used to resolve the newest patched Mattermost tag for platform-triggered releases."
}

# --- Release cutting --------------------------------------------------------
variable "release_tag_regex" {
  type        = string
  description = "Git tag regex that fires a release cut. Defaults to semantic MAJOR.MINOR.PATCH (e.g. 1.2.3), i.e. the *.*.* pattern."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "source_subdir" {
  type        = string
  description = "Sub-directory in the deploy repo that holds the component-specific skaffold-<pipeline>.yaml files. The release is cut with --source=. and an explicit --skaffold-file from here."
  default     = "helm"
}

variable "source_bucket_kms_key_name" {
  type        = string
  description = "Optional CMEK key (full resource ID) for the private source-staging bucket. Wire the shared stack key here to keep the rendered-manifest tarballs CMEK-encrypted like the other data buckets; null uses Google-managed keys."
  default     = null
}

variable "source_retention_days" {
  type        = number
  description = "Age (days) after which uploaded source tarballs in the staging bucket are auto-deleted. They are ephemeral inputs to a release, so they need not be kept."
  default     = 30
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the source-staging bucket."
  default     = {}
}

# --- Wrapper-based delivery through the platform workload profiles -----------
variable "wrapper_releases_enabled" {
  type        = bool
  description = "When true, immutable service tags create Cloud Deploy releases from the service repository's helm/release.yaml and platform-profile release wrappers (assembled by helm/platform/release/assemble.sh from the public platform checkout) instead of the legacy charts under helm/. Requires helm_chart_repository."
  default     = false
}

variable "helm_chart_repository" {
  type = object({
    location      = string
    repository_id = string
  })
  description = "Artifact Registry coordinates of the platform Helm chart OCI repository published by platform-gcp. null disables wrapper releases. Chart publication into it is owned by the separate chart publication rail."
  default     = null
  nullable    = true
}

variable "workload_identity_emails" {
  type        = map(string)
  description = "Workload key => Google service account e-mail. Passed to the release assembler as --identity KEY=EMAIL so a wrapper workload binds its Workload Identity through the manifest `identity` key (default: the workload alias)."
  default     = {}
}

variable "cluster_dns_ip" {
  type        = string
  description = "Exact kube-dns Service ClusterIP forwarded to wrapper releases as the typed network.clusterDNSIP release parameter. Empty omits the parameter."
  default     = ""
}
