variable "project_id" {
  type        = string
  description = "Project the Cloud Build connection, repository, triggers and build identity live in."
}

variable "region" {
  type        = string
  description = "Region for the 2nd-gen connection, repository and triggers (must match Artifact Registry region)."
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply SA (the impersonated identity). Granted actAs on the build SA so it can create triggers that run as a custom, least-privilege identity."
}

# --- GitHub source (shared out-of-band 2nd-gen connection) -----------------
variable "connection_name" {
  type        = string
  description = "Name of the EXISTING Cloud Build 2nd-gen GitHub connection (authorized once in the console via OAuth, see README.md). The source repository is linked to it by its deterministic ID; Terraform never creates or manages the connection."
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the product assembly source repository (service input role mattermost)."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.github_remote_uri))
    error_message = "github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "repository_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen repository resource linking the connection to the source repo."
}

variable "web_github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the private web source pinned by the Mattermost assembly submodule."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.web_github_remote_uri))
    error_message = "web_github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "web_repository_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen repository resource used to mint short-lived read tokens for the private web source."
}

variable "server_source_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the patched server source pinned by the assembly submodule (service input role server_source). Used only for the provenance URLs recorded in the image; no Cloud Build repository link is created for it."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.server_source_remote_uri))
    error_message = "server_source_remote_uri must be an https github.com URL ending in .git."
  }
}

# --- Target registry (ONE unified repository, owned by the artifact_registry component) -----
variable "artifact_registry_location" {
  type        = string
  description = "Location of the unified Artifact Registry repository all images are pushed to (e.g. europe-west3)."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "ID of the unified Artifact Registry repository all images are pushed to (e.g. docker). The build SA gets a single repo-scoped writer binding on it."
}

# --- Image build ------------------------------------------------------------
variable "image_name" {
  type        = string
  description = "Image name (last path segment) pushed under the unified Artifact Registry repository."
  default     = "mattermost"
}

variable "dockerfile" {
  type        = string
  description = "Path to the Dockerfile within the source repo."
  default     = "Dockerfile"
}

variable "builds" {
  type = map(object({
    branch_regex    = optional(string)
    tag_regex       = optional(string)
    delivery        = string
    release_channel = string
  }))
  description = "Build entrypoints. Exactly one of branch_regex or tag_regex must be set; delivery selects a structurally isolated Cloud Deploy pipeline."

  validation {
    condition     = length(var.builds) > 0
    error_message = "Provide at least one build."
  }

  validation {
    condition = alltrue([
      for build in values(var.builds) :
      (build.branch_regex != null) != (build.tag_regex != null)
    ])
    error_message = "Every build must set exactly one of branch_regex or tag_regex."
  }

  validation {
    condition = alltrue([
      for build in values(var.builds) :
      contains(keys(var.mattermost_deliveries), build.delivery)
    ])
    error_message = "Every build.delivery must reference a mattermost_deliveries key."
  }
}

variable "mattermost_deliveries" {
  type = map(object({
    pipeline_name                   = string
    initial_target_name             = string
    execution_service_account_email = string
    deploy_repository_uri           = string
    deploy_repository_ref           = optional(string, "main")
    source_bucket_name              = string
  }))
  description = "Named Mattermost delivery destinations. initial_target_name bounds the Cloud Deploy-generated rollout ID. Preview branches select a dev-only pipeline; release tags select the normal dev-to-prod pipeline."

  validation {
    condition     = length(distinct([for delivery in values(var.mattermost_deliveries) : delivery.source_bucket_name])) == 1
    error_message = "All Mattermost deliveries must share the same release source bucket."
  }
}
