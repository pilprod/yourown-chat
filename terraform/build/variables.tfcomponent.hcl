# ---------------------------------------------------------------------------
# Build-stack inputs. Supplied by the single `build` deployment in
# deployments.tfdeploy.hcl. This stack owns the unified container registry
# (one Artifact Registry repo, named `docker`) and the Mattermost image CI. It does NOT
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
  description = "Short ID of the Secret Manager secret holding the GitHub PAT used by the connection. This stack CREATES the secret container (CMEK-encrypted by the build-owned kms key); only its VALUE/version is added out-of-band before the connection is created."
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
  default     = "docker"
}

variable "image_name" {
  type        = string
  description = "Image name (last path segment) pushed under the unified Artifact Registry repository."
  default     = "mattermost"
}

variable "artifact_registry_kms_key_name" {
  type        = string
  description = "Optional CMEK key (full resource ID) for the registry. The container registry is PUBLIC, so this is null by default (Google-managed keys) and no CMEK dependency on the platform stack exists. The build stack's own kms component supplies the CMEK key for the github-pat secret instead."
  default     = null
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
