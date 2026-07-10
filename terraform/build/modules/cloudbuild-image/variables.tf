variable "project_id" {
  type        = string
  description = "Project the Cloud Build connection, repository, triggers and build identity live in."
}

variable "project_number" {
  type        = string
  description = "Numeric project number, used to derive the Cloud Build service agent (service-<num>@gcp-sa-cloudbuild.iam.gserviceaccount.com) that reads the GitHub PAT."
}

variable "region" {
  type        = string
  description = "Region for the 2nd-gen connection, repository and triggers (must match Artifact Registry region)."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for Cloud Build resource names, e.g. 'yourown-chat'."

  validation {
    # account_id = "${name_prefix}-img-build" must be <= 30 chars; "-img-build"
    # adds 10, so cap the prefix at 20 chars.
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric/hyphen, starting with a letter, <= 20 chars."
  }
}

variable "apply_service_account_email" {
  type        = string
  description = "Terraform apply SA (the impersonated identity). Granted actAs on the build SA so it can create triggers that run as a custom, least-privilege identity."
}

# --- GitHub source (2nd-gen connection) ------------------------------------
variable "connection_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen GitHub connection."
  default     = "github"
}

variable "github_app_installation_id" {
  type        = number
  description = "Installation ID of the Cloud Build GitHub App on the source account/org (from the one-time OAuth authorize during bootstrap). The provider field app_installation_id is numeric."
}

variable "github_pat_secret_id" {
  type        = string
  description = "Short ID of the Secret Manager secret holding the GitHub personal access token used by the connection. Created and populated out-of-band during bootstrap (never in git)."
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

# --- Target registry (ONE unified repository, owned by this build stack) -----
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

variable "labels" {
  type        = map(string)
  description = "Labels applied to labellable resources."
  default     = {}
}
