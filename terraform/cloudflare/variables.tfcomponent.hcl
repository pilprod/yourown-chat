# ---------------------------------------------------------------------------
# CLOUDFLARE stack inputs. The ingress IP arrives in cloudflare.tfdeploy.hcl as
# upstream_input from the LINKED platform-gcp stack; the API token comes from
# an HCP variable set. Everything else is edge configuration.
# ---------------------------------------------------------------------------

variable "ingress_ip_address" {
  type        = string
  description = "Reserved static external ingress IP the proxied apex A record points at. Published by the platform-gcp stack (upstream_input.platform.ingress_ip_address). Only consumed when public_ingress_enabled = true."
  default     = null
}

variable "public_ingress_enabled" {
  type        = bool
  description = "Provision the public edge (DNS + settings + WAF + origin TLS). MUST match the platform-gcp deployment's public_ingress_enabled (which reserves the static IP this edge points at). Enable for prod only; dev stays private."
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
  description = "Issue a Cloudflare Origin CA cert from Terraform for Full (Strict) TLS. On by default (matches ssl_mode=strict). Needs SSL and Certificates: Edit on the token. The cert/key are PUBLISHED to the app-gcp stack, which pours them into the mattermost-origin-tls-* secrets -- no manual step."
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
