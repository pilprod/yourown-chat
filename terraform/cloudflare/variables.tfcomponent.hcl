# ---------------------------------------------------------------------------
# Cloudflare-stack inputs. Supplied by the single `cloudflare` deployment in
# deployments.tfdeploy.hcl. This stack owns the public-edge configuration for
# the origin: DNS, edge TLS/security settings, DNSSEC, WAF rules and optional
# origin TLS. It has no GCP dependency at apply time -- it only needs the
# reserved ingress IP that the platform stack exposes as its ingress_ip_address
# output.
#
# Free-plan features are on by default; paid features (managed WAF ruleset, rate
# limiting) default off so a Free-plan apply never fails.
# ---------------------------------------------------------------------------

variable "cloudflare_api_token" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Cloudflare API token scoped to the yourown.chat zone (Zone:Read, DNS:Edit, Zone Settings:Edit; + SSL and Certificates:Edit if managing origin cert/AOP). Ephemeral: never persisted to state. Sourced from an HCP variable set (see docs/INIT.md)."
}

variable "domain" {
  type        = string
  description = "Cloudflare zone / apex domain fronting the origin."
  default     = "yourown.chat"
}

variable "ingress_ip_address" {
  type        = string
  description = "Reserved regional external IP of the public ingress LB. Copy it from the platform stack's ingress_ip_address output (the IP is stable by design, so a one-time hand-off is safe). The proxied apex A record points here."

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.ingress_ip_address))
    error_message = "Set ingress_ip_address to the platform stack's ingress_ip_address output (a bare IPv4). The empty/sentinel default blocks the plan until you do."
  }
}

variable "proxied" {
  type        = bool
  description = "Whether the apex A record is proxied (orange cloud). Keep true so Cloudflare fronts the origin."
  default     = true
}

variable "manage_www" {
  type        = bool
  description = "Create a proxied www CNAME pointing at the apex."
  default     = true
}

variable "extra_records" {
  type = map(object({
    name     = string
    type     = string
    content  = string
    proxied  = optional(bool, false)
    ttl      = optional(number, 300)
    priority = optional(number)
    comment  = optional(string, "Managed by Terraform (cloudflare stack).")
  }))
  description = "Arbitrary extra DNS records keyed by a stable logical name (MX/TXT/SPF/DKIM/DMARC/verification/...)."
  default     = {}
}

variable "caa_records" {
  type = list(object({
    flags = optional(number, 0)
    tag   = string
    value = string
  }))
  description = "CAA records restricting which CAs may issue for the zone. Empty by default."
  default     = []
}

# --- Edge TLS / security settings (Free-safe) -------------------------------
variable "ssl_mode" {
  type        = string
  description = "Cloudflare SSL/TLS mode. 'strict' = Full (Strict)."
  default     = "strict"
}

variable "always_use_https" {
  type        = string
  description = "Redirect plaintext to HTTPS at the edge ('on'/'off')."
  default     = "on"
}

variable "min_tls_version" {
  type        = string
  description = "Minimum TLS version the edge accepts from clients. 1.3 by default."
  default     = "1.3"
}

variable "hsts" {
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

variable "dnssec_enabled" {
  type        = bool
  description = "Activate DNSSEC; publish the returned DS record at the registrar to complete it."
  default     = true
}

# --- WAF / rules ------------------------------------------------------------
variable "custom_firewall_rules" {
  type = list(object({
    expression  = string
    action      = string
    description = string
    enabled     = optional(bool, true)
  }))
  description = "WAF custom rules (Free, limited count). No ruleset when empty."
  default     = []
}

variable "managed_waf_enabled" {
  type        = bool
  description = "Deploy the Cloudflare Managed Ruleset (WAF). PAID (Pro+); leave false on Free."
  default     = false
}

variable "rate_limit_rules" {
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

# --- Optional origin TLS (default off) --------------------------------------
variable "manage_origin_cert" {
  type        = bool
  description = "Issue a Cloudflare Origin CA cert from Terraform for Full (Strict) TLS. On by default (matches ssl_mode=strict). Needs SSL and Certificates: Edit on the token; load the (sensitive) cert/key outputs into the platform mattermost-origin-tls-* secrets."
  default     = true
}

variable "aop_enabled" {
  type        = bool
  description = "Enable per-hostname Authenticated Origin Pulls. Requires aop_certificate/aop_private_key. Off by default."
  default     = false
}

variable "aop_certificate" {
  type        = string
  description = "PEM client cert the edge presents to the origin (per-hostname AOP)."
  default     = ""
}

variable "aop_private_key" {
  type        = string
  sensitive   = true
  description = "PEM private key for the AOP client certificate."
  default     = ""
}
