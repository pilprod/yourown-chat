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
  default     = "pilprod-github"
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the source repository, e.g. https://github.com/pilprod/mattermost.git."

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.github_remote_uri))
    error_message = "github_remote_uri must be an https github.com URL ending in .git."
  }
}

variable "repository_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen repository resource linking the connection to the source repo."
  default     = "mattermost"
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
    tag_regex = string
  }))
  description = "Map of image name => spec. Each entry creates one tag-triggered Cloud Build trigger that builds var.dockerfile and pushes <ar_location>-docker.pkg.dev/<project>/<ar_repo>/<image_name>:$TAG_NAME. Build once on the tag regex (e.g. ^v.*-patched$) and promote that same artifact across environments, rather than rebuilding per environment."

  validation {
    condition     = length(var.builds) > 0
    error_message = "Provide at least one build."
  }
}
