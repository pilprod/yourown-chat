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

# --- Cluster bootstrap (operator + ingress-nginx Helm releases) --------------
variable "ingress_ip_address" {
  type        = string
  description = "Reserved static ingress IP (the Cloudflare-facing 'white address'). Published by the platform-gcp stack; injected into the ingress-nginx values as loadBalancerIP. null skips the ingress-nginx release."
  default     = null
}

variable "mattermost_operator_chart_version" {
  type        = string
  description = "mattermost/mattermost-operator chart version (https://helm.mattermost.com). Pinned for reproducible bootstrap; bump deliberately."
}

variable "ingress_nginx_chart_version" {
  type        = string
  description = "ingress-nginx/ingress-nginx chart version (https://kubernetes.github.io/ingress-nginx). Pinned for reproducible bootstrap; bump deliberately."
}

variable "adopt_existing_cluster_bootstrap_releases" {
  type        = bool
  description = "Import pre-existing cluster bootstrap Helm releases (mattermost-operator and ingress-nginx) that were installed by an interrupted/previous apply but are not yet in Terraform state."
  default     = false
}

variable "manage_ingress_origin_tls" {
  type        = bool
  description = "Materialise the mattermost-origin-tls Kubernetes Secret (Cloudflare Origin CA cert/key, for the ingress Full (Strict) TLS) from the Secret Manager values the cloudflare stack writes. Set from the cloudflare stack's origin_secret_ids in the deployment; false skips it (no public ingress)."
  default     = false
}

variable "aop_enabled" {
  type        = bool
  description = "Authenticated Origin Pulls (per-hostname mTLS) enforcement for the ingress -- derived in the deployment from the cloudflare stack's published aop_enabled, not set by hand. Only toggles the ingress verify-client: the cloudflare-origin-pull-ca Kubernetes Secret is materialised whenever origin TLS is managed (its CA is self-generated by the cloudflare stack), so annotation parsing never fails. true = enforce client-cert verification; false = Full (Strict) TLS only (CA loaded but inert)."
  default     = false
}

variable "adopt_existing_namespaces" {
  type        = bool
  description = "Import the tenant namespaces (dev/matterbridge/mattermost) if they already exist in the cluster (e.g. created by a previous Cloud Deploy namespaces.yaml) instead of failing with 'already exists'. Set true for the one-time adoption apply, then back to false."
  default     = false
}

variable "matterbridge_enabled" {
  type        = bool
  description = "Deploy matterbridge (the chat bridge) as part of the dev Cloud Deploy stage. true -> the 'matterbridge' Skaffold profile is appended to the dev target (SA + NetworkPolicy + SecretProviderClass + Deployment rendered) and the matterbridge namespace is created; false -> the dev target renders only the dev tenant, matterbridge is not deployed, and its namespace is removed. The matterbridge-tokens Secret Manager secret is kept either way (preserves an operator-supplied token across a toggle)."
  default     = true
}

variable "mcp_servers_enabled" {
  type        = bool
  description = "Deploy the in-cluster MCP (Model Context Protocol) servers with the prod Cloud Deploy stage. true -> the 'mcp-servers' Skaffold profile is appended to the prod target and helm/mcp-servers renders every server enabled in its values.yaml (the per-server switchboard); false -> no MCP servers are deployed. Vendor-hosted remote MCP endpoints (Figma, Miro, Cloudflare, Atlassian, ...) need no deployment and are unaffected -- see docs/MCP.md."
  default     = false
}

variable "zero_trust_mcp_enabled" {
  type        = bool
  description = "Materialise the mcp-tunnel Kubernetes Secret (cloudflared run token, written to Secret Manager by the cloudflare stack's zero_trust_mcp component) so the tunnel pod in helm/mcp-servers can start. MUST follow the cloudflare stack's zero_trust_mcp_enabled: enabling it here first would 404 on the missing Secret Manager secret. The chart-side switch is tunnel.enabled in helm/mcp-servers/values.yaml."
  default     = false
}

variable "dev_team_rbac_subjects" {
  type = list(object({
    kind = string
    name = string
  }))
  description = "Dev-team RBAC subjects granted edit rights in the `dev` namespace (Google Group or Users). Empty (default) creates no RBAC. Created by Terraform, NOT Cloud Deploy (whose execution SA cannot manage RBAC). A Group subject requires 'Google Groups for GKE RBAC' on the cluster."
  default     = []
}
