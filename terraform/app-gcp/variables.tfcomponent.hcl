# ---------------------------------------------------------------------------
# APP-GCP stack inputs. Values are supplied by app.tfdeploy.hcl. The upstream-owned
# values (cluster ID, registry coordinates, CMEK key, Workload Identity
# members) arrive there as upstream_input from the
# LINKED platform-gcp stack -- declared here as ordinary variables, so the components stay
# testable and the linkage is confined to the deployment file.
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID for this environment."
}

variable "environment" {
  type        = string
  description = "Environment name (drives labels only)."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "region" {
  type        = string
  description = "Primary region. europe-west3 = Frankfurt, Germany. Also the Cloud Build / Cloud Deploy region."
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
  description = "Least-privilege GCP apply SA impersonated by Terraform via WIF (never Owner/Editor). Also granted actAs on the build SA so it can create triggers that run as that identity."
}

# --- Values published by the LINKED platform-gcp stack -----------------------
variable "gke_cluster_id" {
  type        = string
  description = "Full GKE cluster resource ID (projects/<p>/locations/<l>/clusters/<n>) shared by every Cloud Deploy target. Published by the platform stack (upstream_input.platform.gke_cluster_id)."
}

variable "artifact_registry_location" {
  type        = string
  description = "Artifact Registry location the image CI pushes to. Published by the platform stack."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry repository ID the image CI pushes to. Published by the platform stack."
}

variable "cmek_key_id" {
  type        = string
  description = "Shared CMEK key resource ID encrypting this stack's secrets and the release-source bucket (null when the platform runs cmek_enabled = false). Published by the platform stack."
  default     = null
}

variable "workload_identity_members" {
  type        = map(string)
  description = "Tenant (mattermost/matterbridge/dev) => IAM member string (serviceAccount:<email>) used as least-privilege secretAccessor grants. Published by the platform stack."
}

# --- Image-build CI (Cloud Build 2nd-gen) ------------------------------------
variable "github_connection_name" {
  type        = string
  description = "Name of the EXISTING Cloud Build 2nd-gen GitHub connection, authorized once in the console via OAuth (see README.md). Both the image and deploy repositories are linked to it by ID; Terraform never creates or manages the connection."
  default     = "pilprod-github"
}

variable "github_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the Mattermost source repository."
  default     = "https://github.com/pilprod/mattermost.git"
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
  default = {
    mattermost = { tag_regex = "^v.*-patched$" }
  }
}

# --- Automated release cutting (Cloud Deploy on a git tag) ------------------
variable "github_deploy_remote_uri" {
  type        = string
  description = "HTTPS clone URL of the DEPLOY repository (the one holding helm/, i.e. this repo). A second Cloud Build 2nd-gen repository link points here so a semver tag cuts a Cloud Deploy release automatically. The Cloud Build GitHub App + PAT must cover this repo too (see README.md)."
  default     = "https://github.com/pilprod/yourown-chat.git"
}

variable "release_tag_regex" {
  type        = string
  description = "Git tag regex (on the deploy repo) that triggers an automatic Cloud Deploy release cut. Defaults to semantic MAJOR.MINOR.PATCH — the *.*.* pattern (e.g. 1.2.3)."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

# --- Labels -----------------------------------------------------------------
variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto every labellable resource."
  default     = {}
}

variable "gcs_bucket_name" {
  type        = string
  description = "Mattermost object-storage bucket name. Published by the platform-gcp stack; rendered into the operator CR (spec.fileStore.external.bucket) via Cloud Deploy deploy parameters."
}

variable "workload_identity_emails" {
  type        = map(string)
  description = "Tenant (mattermost/matterbridge/dev) => GSA email. Published by the platform-gcp stack; rendered into the KSA iam.gke.io/gcp-service-account annotations via Cloud Deploy deploy parameters."
}
