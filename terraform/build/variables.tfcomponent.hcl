# ---------------------------------------------------------------------------
# Build-stack inputs. Supplied by the single `build` deployment in
# deployments.tfdeploy.hcl. This stack owns the unified container registry
# (one yourown-chat-containers repository) and the Mattermost image CI. It does NOT
# enable APIs (the platform stack owns artifactregistry/cloudbuild activation
# and must be applied first). Its build SA gets a single repo-scoped writer
# binding on the registry it creates.
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "GCP project ID that hosts the build CI (same project as the platform stack)."
}

variable "project_number" {
  type        = string
  description = "Numeric project number. Used to derive the Cloud Build service agent that reads the GitHub PAT."
}

variable "region" {
  type        = string
  description = "Region for the Cloud Build 2nd-gen connection, repository and triggers. Must match the Artifact Registry region."
  default     = "europe-west3"
}

variable "name_prefix" {
  type        = string
  description = "Short platform prefix used in build resource names (matches the platform stack's project_prefix)."
  default     = "yourown-chat"
}

# --- Keyless auth: HCP Dynamic Provider Credentials -> GCP WIF ---------------
variable "identity_token" {
  type        = string
  ephemeral   = true
  description = "HCP Terraform OIDC JWT, minted per run. Ephemeral: never persisted to stack state."
}

variable "audience" {
  type        = string
  description = "STS audience = full WIF provider resource name (//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID>)."
}

variable "service_account_email" {
  type        = string
  description = "Least-privilege GCP apply SA impersonated by Terraform via WIF. Also granted actAs on the build SA so it can create triggers that run as that identity."
}

# --- GitHub source (Cloud Build 2nd-gen) ------------------------------------
variable "github_app_installation_id" {
  type        = number
  description = "Installation ID of the Cloud Build GitHub App on the source account/org (from the one-time OAuth authorize during bootstrap). Numeric (provider field app_installation_id is a number)."

  validation {
    condition     = var.github_app_installation_id > 0
    error_message = "Set the real GitHub App installation ID (a positive number) before applying. See docs/BUILD.md."
  }
}

variable "github_pat_secret_id" {
  type        = string
  description = "Short ID of the Secret Manager secret holding the GitHub PAT used by the connection. Created and populated out-of-band before the first apply."
  default     = "github-pat"
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the Mattermost source repository."
  default     = "https://github.com/pilprod/mattermost.git"
}

# --- Registry + image -------------------------------------------------------
variable "artifact_registry_repository_id" {
  type        = string
  description = "ID of the unified Artifact Registry repository this stack creates and pushes every image to (shared across environments; images are promoted by tag, not duplicated per env)."
  default     = "yourown-chat-containers"
}

variable "image_name" {
  type        = string
  description = "Image name (last path segment) pushed under the unified Artifact Registry repository."
  default     = "mattermost"
}

variable "builds" {
  type = map(object({
    tag_regex = string
  }))
  description = "Map of image name => git tag regex. Each entry creates one tag-triggered Cloud Build trigger pushing the unified image path. Build once on the tag pattern (^v.*-patched$) and promote that artifact dev -> prod, rather than rebuilding per environment."
}

variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto labellable resources."
  default     = {}
}
