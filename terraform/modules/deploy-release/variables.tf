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
variable "connection_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen GitHub connection for the deploy repository. Separate from the image-CI connection so the release repo has its own lifecycle."
  default     = "github-deploy"
}

variable "repository_name" {
  type        = string
  description = "Name of the Cloud Build 2nd-gen repository resource linking the connection to the deploy source repo."
  default     = "yourown-chat"
}

variable "github_app_installation_id" {
  type        = number
  description = "Installation ID of the Cloud Build GitHub App on the account/org owning the deploy repo (same one-time OAuth authorize as the image CI; the App must cover this repo too). The provider field app_installation_id is numeric."
}

variable "github_pat_secret_id" {
  type        = string
  description = "Short ID of the Secret Manager secret holding the GitHub PAT used by the connection. Created and populated out-of-band during bootstrap (see README.md); the stack only references it. The Cloud Build service agent's read grant is owned by the image-CI component (shared project singleton)."
  default     = "github-pat"
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the deploy source repository (the one holding helm/), e.g. https://github.com/pilprod/yourown-chat.git."
  default     = "https://github.com/pilprod/yourown-chat.git"

  validation {
    condition     = can(regex("^https://github\\.com/.+\\.git$", var.github_remote_uri))
    error_message = "github_remote_uri must be an https github.com URL ending in .git."
  }
}

# --- Cloud Deploy target (from the clouddeploy component) --------------------
variable "delivery_pipeline_name" {
  type        = string
  description = "Name of the Cloud Deploy delivery pipeline releases are cut against. The releaser SA is granted roles/clouddeploy.releaser on THIS pipeline only (never project-wide)."
}

variable "execution_service_account_email" {
  type        = string
  description = "Email of the Cloud Deploy execution SA. The releaser must actAs it, because creating a release runs the render/deploy jobs as this identity."
}

# --- Release cutting --------------------------------------------------------
variable "release_tag_regex" {
  type        = string
  description = "Git tag regex that fires a release cut. Defaults to semantic MAJOR.MINOR.PATCH (e.g. 1.2.3), i.e. the *.*.* pattern."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "source_subdir" {
  type        = string
  description = "Sub-directory in the deploy repo that holds skaffold.yaml (the Cloud Deploy render root). The release is cut with --source=. from here."
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

# --- Sequencing handle ------------------------------------------------------
variable "pat_secret_grant_dependency" {
  type        = string
  description = "Opaque handle: the ID of the Cloud Build service agent's secretAccessor grant on the PAT, a project singleton owned by the image-CI component. Threading it in orders this component AFTER that grant so this connection validates against a readable secret (the grant is never re-created here, which would conflict)."
  default     = null
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to the source-staging bucket."
  default     = {}
}
