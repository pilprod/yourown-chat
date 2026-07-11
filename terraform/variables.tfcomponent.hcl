# ---------------------------------------------------------------------------
# Unified stack inputs. Values are supplied per-environment by the deployment
# blocks in deployments.tfdeploy.hcl. One deployment (eu) provisions the
# whole product: the GCP platform, the image-build CI and the Cloudflare edge.
#
# Naming: resources are named by ROLE (Workload Identity SAs) or REGIONALLY
# (europe-west3-*), never by environment or project -- the project is already
# `yourown-chat`, so a yourown-chat-* prefix would just repeat it. `environment`
# drives labels only.
#
# TOPOLOGY: the budget-optimized default is ONE zonal GKE cluster with two node
# pools (prod + dev tiers) instead of separate clusters per environment. See
# deployments.tfdeploy.hcl and the README for the rationale and the scale-out
# path (raising the budget to run stage/prod as separate deployments).
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID for this environment."
}

variable "environment" {
  type        = string
  description = "Environment name (drives labels only; resource names are role-based or regional, never environment-scoped). The single-cluster budget default uses 'prod' as the platform cluster; dev workloads run as a tenant namespace on the dev node pool."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "region" {
  type        = string
  description = "Primary region. europe-west3 = Frankfurt, Germany. Also the Cloud Build / Artifact Registry region."
  default     = "europe-west3"
}

variable "zone" {
  type        = string
  description = "Zone used for a zonal (cheapest) GKE cluster."
  default     = "europe-west3-b"
}

# --- Keyless auth: HCP Dynamic Provider Credentials -> GCP WIF ---------------
# No static credentials, SA keys, or JSON exist anywhere in this repo. HCP mints
# a short-lived OIDC JWT per run (identity_token block in deployments.tfdeploy.
# hcl); the google provider exchanges it through Workload Identity Federation
# and impersonates a least-privilege service account. See README.md.
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

# --- Image-build CI (Cloud Build 2nd-gen + Artifact Registry) ---------------
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

variable "artifact_registry_repository_id" {
  type        = string
  description = "ID of the unified Artifact Registry repository the stack creates and pushes every image to (shared across environments; images are promoted by tag, not duplicated per env)."
  default     = "docker"
}

variable "image_name" {
  type        = string
  description = "Image name (last path segment) pushed under the unified Artifact Registry repository."
  default     = "mattermost"
}

variable "artifact_registry_kms_key_name" {
  type        = string
  description = "Optional CMEK key (full resource ID) for the registry. The container registry is PUBLIC, so this is null by default (Google-managed keys)."
  default     = null
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
  description = "HTTPS clone URL of the DEPLOY repository (the one holding helm/, i.e. this repo). A second Cloud Build 2nd-gen connection points here so a semver tag cuts a Cloud Deploy release automatically. The Cloud Build GitHub App + PAT must cover this repo too (see README.md)."
  default     = "https://github.com/pilprod/yourown-chat.git"
}

variable "release_tag_regex" {
  type        = string
  description = "Git tag regex (on the deploy repo) that triggers an automatic Cloud Deploy release cut. Defaults to semantic MAJOR.MINOR.PATCH — the *.*.* pattern (e.g. 1.2.3)."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

# --- GKE cost / topology knobs ---------------------------------------------
variable "gke_regional" {
  type        = bool
  description = "true = regional (HA) control plane; false = zonal (cheapest, free tier)."
  default     = false
}

variable "gke_node_pools" {
  type = map(object({
    machine_type = optional(string, "e2-small")
    spot         = optional(bool, false)
    min_count    = optional(number, 1)
    max_count    = optional(number, 2)
    disk_size_gb = optional(number, 30)
    disk_type    = optional(string, "pd-standard")
    labels       = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  description = "Map of node pool name => spec. Isolate workload tiers on one cluster via labels/taints (e.g. a tainted prod pool + an untainted dev pool)."

  default = {
    prod = {
      machine_type = "e2-standard-2"
      spot         = false
      min_count    = 1
      max_count    = 2
      disk_size_gb = 30
      labels       = { tier = "prod" }
      taints       = [{ key = "dedicated", value = "prod", effect = "NO_SCHEDULE" }]
    }
    dev = {
      machine_type = "e2-small"
      spot         = false
      min_count    = 1
      max_count    = 1
      disk_size_gb = 30
      labels       = { tier = "dev" }
      taints       = []
    }
  }
}

variable "gke_deletion_protection" {
  type        = bool
  description = "Protect the GKE cluster from deletion."
  default     = true
}

variable "master_authorized_networks" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  description = "CIDRs allowed to reach the GKE control-plane endpoint."
  default     = []
}

# --- Cloud SQL cost / HA / backup knobs ------------------------------------
variable "cloudsql_enabled" {
  type        = bool
  description = "Provision a managed Cloud SQL instance. Set false for cost-minimized environments (e.g. dev) that use the in-cluster Postgres StatefulSet instead."
  default     = true
}

variable "cloudsql_tier" {
  type        = string
  description = "Cloud SQL machine tier."
  default     = "db-f1-micro"
}

variable "cloudsql_availability_type" {
  type        = string
  description = "ZONAL (cheapest) or REGIONAL (HA)."
  default     = "ZONAL"
}

variable "cloudsql_disk_size_gb" {
  type        = number
  description = "Cloud SQL initial disk size."
  default     = 20
}

variable "cloudsql_pitr_enabled" {
  type        = bool
  description = "Enable point-in-time recovery (WAL archiving). Cheap insurance against data loss without HA."
  default     = true
}

variable "cloudsql_backup_retained_count" {
  type        = number
  description = "Number of automated backups to retain."
  default     = 7
}

variable "cloudsql_txlog_retention_days" {
  type        = number
  description = "Days of transaction logs retained for PITR."
  default     = 7
}

variable "cloudsql_deletion_protection" {
  type        = bool
  description = "Protect the Cloud SQL instance from deletion."
  default     = true
}

# --- Storage ----------------------------------------------------------------
variable "storage_force_destroy" {
  type        = bool
  description = "Allow Terraform to delete the bucket even if it is non-empty."
  default     = false
}

# --- Encryption (CMEK) ------------------------------------------------------
# One shared Cloud KMS key encrypts every at-rest store that supports CMEK
# (Cloud SQL, GCS, Secret Manager). At-rest data is AES-256 either way; CMEK
# puts the key lifecycle (rotation, disable, destroy = crypto-shred) under our
# control instead of Google's. The PUBLIC Artifact Registry is deliberately not
# CMEK-encrypted, so it takes no key.
variable "cmek_enabled" {
  type        = bool
  description = "Provision the shared Cloud KMS key and encrypt Cloud SQL + GCS + Secret Manager with it. Cost is ~$1/mo for an HSM key version (or ~$0.06 for SOFTWARE). Note: Cloud SQL binds its key at creation, so toggling this on an existing deployment replaces that instance."
  default     = true
}

variable "kms_protection_level" {
  type        = string
  description = "CMEK key protection level. HSM = FIPS 140-2 Level 3 hardware custody (~$1.00/version/mo); SOFTWARE = Level 1 (~$0.06). Immutable once the key exists -- moving between them later means a new key (and, for Cloud SQL, an instance migration)."
  default     = "HSM"

  validation {
    condition     = contains(["HSM", "SOFTWARE"], var.kms_protection_level)
    error_message = "kms_protection_level must be HSM or SOFTWARE."
  }
}

variable "kms_rotation_period" {
  type        = string
  description = "Automatic rotation period for the shared key, in seconds with an 's' suffix. Default 90 days."
  default     = "7776000s"
}

# --- Public ingress (Cloudflare-fronted) ------------------------------------
variable "public_ingress_enabled" {
  type        = bool
  description = "Provision the public ingress path for this environment: a reserved static IP (the Cloudflare-facing 'white address'), the Secret Manager containers for the origin TLS keypair and the Authenticated Origin Pulls CA, AND the Cloudflare edge component (DNS + settings + WAF). Enable for prod only; dev stays private."
  default     = false
}

# --- Cloudflare edge (only used when public_ingress_enabled = true) ----------
# Free-plan features are on by default; paid features (managed WAF ruleset, rate
# limiting) default off so a Free-plan apply never fails. The apex A record is
# wired LIVE to the platform ingress IP (component.network.ingress_ip_address),
# so there is no manual IP hand-off.
variable "cloudflare_api_token" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Cloudflare API token scoped to the yourown.chat zone (Zone:Read, DNS:Edit, Zone Settings:Edit; + SSL and Certificates:Edit if managing origin cert/AOP). Ephemeral: never persisted to state. Sourced from an HCP variable set (see README.md)."
}

variable "domain" {
  type        = string
  description = "Cloudflare zone / apex domain fronting the origin."
  default     = "yourown.chat"
}

variable "cloudflare_proxied" {
  type        = bool
  description = "Whether the apex A record is proxied (orange cloud). Keep true so Cloudflare fronts the origin."
  default     = true
}

variable "cloudflare_manage_www" {
  type        = bool
  description = "Create a proxied www CNAME pointing at the apex."
  default     = true
}

variable "cloudflare_extra_records" {
  type = map(object({
    name     = string
    type     = string
    content  = string
    proxied  = optional(bool, false)
    ttl      = optional(number, 300)
    priority = optional(number)
    comment  = optional(string, "Managed by Terraform.")
  }))
  description = "Arbitrary extra DNS records keyed by a stable logical name (MX/TXT/SPF/DKIM/DMARC/verification/...)."
  default     = {}
}

variable "cloudflare_caa_records" {
  type = list(object({
    flags = optional(number, 0)
    tag   = string
    value = string
  }))
  description = "CAA records restricting which CAs may issue for the zone. Empty by default."
  default     = []
}

variable "cloudflare_ssl_mode" {
  type        = string
  description = "Cloudflare SSL/TLS mode. 'strict' = Full (Strict)."
  default     = "strict"
}

variable "cloudflare_always_use_https" {
  type        = string
  description = "Redirect plaintext to HTTPS at the edge ('on'/'off')."
  default     = "on"
}

variable "cloudflare_min_tls_version" {
  type        = string
  description = "Minimum TLS version the edge accepts from clients. 1.3 by default."
  default     = "1.3"
}

variable "cloudflare_hsts" {
  type = object({
    enabled            = optional(bool, true)
    max_age            = optional(number, 31536000)
    include_subdomains = optional(bool, true)
    preload            = optional(bool, true)
    nosniff            = optional(bool, true)
  })
  description = "HSTS (security_header) config. Enabled with 1-year max-age by default."
  default     = {}
}

variable "cloudflare_dnssec_enabled" {
  type        = bool
  description = "Activate DNSSEC; publish the returned DS record at the registrar to complete it."
  default     = true
}

variable "cloudflare_custom_firewall_rules" {
  type = list(object({
    expression  = string
    action      = string
    description = string
    enabled     = optional(bool, true)
  }))
  description = "WAF custom rules (Free, limited count). No ruleset when empty."
  default     = []
}

variable "cloudflare_managed_waf_enabled" {
  type        = bool
  description = "Deploy the Cloudflare Managed Ruleset (WAF). PAID (Pro+); leave false on Free."
  default     = false
}

variable "cloudflare_rate_limit_rules" {
  type = list(object({
    expression          = string
    action              = string
    description         = string
    period              = number
    requests_per_period = number
    mitigation_timeout  = number
    characteristics     = list(string)
  }))
  description = "Rate limiting rules. PAID/advanced; leave empty on Free."
  default     = []
}

variable "cloudflare_manage_origin_cert" {
  type        = bool
  description = "Issue a Cloudflare Origin CA cert from Terraform for Full (Strict) TLS. On by default (matches ssl_mode=strict). Needs SSL and Certificates: Edit on the token. The cert/key flow straight into the platform mattermost-origin-tls-* secrets -- no manual step."
  default     = true
}

variable "cloudflare_aop_enabled" {
  type        = bool
  description = "Enable per-hostname Authenticated Origin Pulls. Requires cloudflare_aop_certificate/cloudflare_aop_private_key. Off by default."
  default     = false
}

variable "cloudflare_aop_certificate" {
  type        = string
  description = "PEM client cert the edge presents to the origin (per-hostname AOP)."
  default     = ""
}

variable "cloudflare_aop_private_key" {
  type        = string
  sensitive   = true
  description = "PEM private key for the AOP client certificate."
  default     = ""
}

# --- Labels -----------------------------------------------------------------
variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto every labellable resource."
  default     = {}
}
