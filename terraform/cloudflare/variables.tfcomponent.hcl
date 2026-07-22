# ---------------------------------------------------------------------------
# CLOUDFLARE stack inputs. The platform-published values (ingress IP, CMEK key,
# Workload Identity members) arrive in cloudflare.tfdeploy.hcl as
# upstream_input from the LINKED platform-gcp stack; the API token comes from
# an HCP variable set. Everything else is edge configuration.
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID (for the origin-TLS Secret Manager containers this stack fills)."
}

variable "region" {
  type        = string
  description = "Primary region for the secret replicas. europe-west3 = Frankfurt, Germany."
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
  description = "Least-privilege GCP apply SA impersonated by Terraform via WIF (never Owner/Editor)."
}

# --- Values published by the LINKED platform-gcp stack -----------------------
variable "ingress_ip_address" {
  type        = string
  description = "Reserved static external ingress IP the proxied apex A record points at. Published by the platform-gcp stack (upstream_input.platform.ingress_ip_address). Only consumed when public_ingress_enabled = true."
  default     = null
}

variable "cmek_key_id" {
  type        = string
  description = "Shared CMEK key resource ID encrypting the origin-TLS secret replicas (null when the platform runs cmek_enabled = false). Published by the platform-gcp stack."
  default     = null
}

variable "workload_identity_members" {
  type        = map(string)
  description = "Tenant (mattermost/matterbridge/dev) => IAM member string (serviceAccount:<email>); the mattermost member reads the origin-TLS secrets. Published by the platform-gcp stack."
}

variable "public_ingress_enabled" {
  type        = bool
  description = "Provision the public edge (DNS + settings + WAF + origin TLS + the origin-TLS secret containers). MUST match the platform-gcp deployment's public_ingress_enabled (which reserves the static IP this edge points at). Enable for prod only; dev stays private."
  default     = false
}

# --- Cloudflare edge ----------------------------------------------------------
# Free-plan features are on by default; paid features (managed WAF ruleset, rate
# limiting) default off so a Free-plan apply never fails.
variable "cloudflare_api_token" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Cloudflare API token scoped to the yourown.chat zone (Zone:Read, DNS:Edit, Zone Settings:Edit, Single Redirect:Edit; + SSL and Certificates:Edit if managing origin cert/AOP). Ephemeral: never persisted to state. Sourced from an HCP variable set (see README.md)."
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
  description = "Issue a Cloudflare Origin CA cert from Terraform for Full (Strict) TLS. On by default (matches ssl_mode=strict). Needs SSL and Certificates: Edit on the token. The cert/key are written straight into the mattermost-origin-tls-* Secret Manager containers by this stack -- no manual step, and the private key never crosses a stack boundary."
  default     = true
}

# --- Zero Trust (flagged) ------------------------------------------------------
variable "zero_trust_enabled" {
  type        = bool
  description = "Expose private in-cluster services (internal MCP servers, dev Mattermost) through Cloudflare Zero Trust: Access email allow-list -> Tunnel -> ClusterIP, no public origin exposure. Requires zero_trust_upstreams, zero_trust_allowed_emails and an ACCOUNT-scoped API token (Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit) -- the account ID itself is derived from the zone. The flag is the kill switch if the beta claude.ai <-> MCP-portal interop misbehaves (docs/MCP.md smoke test); the dev Mattermost browser path has no beta dependency."
  default     = false
}

variable "zero_trust_upstreams" {
  type        = map(string)
  description = "Hostname label => in-cluster service URL routed through the tunnel (one DNS record + Access app each). Only used when zero_trust_enabled = true."
  default     = {}
}

variable "zero_trust_allowed_emails" {
  type        = list(string)
  description = "Emails admitted by the Access policy on every MCP hostname (Zero Trust Free covers 50 users). Only used when zero_trust_enabled = true."
  default     = []
}

variable "cloudflare_aop_enabled" {
  type        = bool
  description = "Enforce per-hostname Authenticated Origin Pulls. The self-signed client cert/CA is generated automatically (no material to supply); this only gates whether the edge presents it AND is the single root AOP toggle -- app-gcp derives its ingress verify-client from the published aop_enabled output. Off by default (Full (Strict) TLS only). MUST be applied before app-gcp."
  default     = false
}
