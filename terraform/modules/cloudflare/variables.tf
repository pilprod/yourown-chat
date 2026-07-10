# ===========================================================================
# Core zone / DNS
# ===========================================================================
variable "domain" {
  type        = string
  description = "Cloudflare zone (apex domain), e.g. yourown.chat. Used to look up the zone ID and as the default record name."

  validation {
    condition     = can(regex("^([a-z0-9-]+\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a bare apex domain like yourown.chat (no scheme, no trailing dot)."
  }
}

variable "record_name" {
  type        = string
  description = "Name of the apex A record. Defaults to the zone itself."
  default     = null
}

variable "origin_ip" {
  type        = string
  description = "IPv4 the proxied apex A record points at: the network component's reserved ingress IP (ingress_ip_address output)."

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}$", var.origin_ip))
    error_message = "origin_ip must be a bare IPv4 address (the network ingress_ip_address output). Do not pass a URL or an empty string."
  }
}

variable "proxied" {
  type        = bool
  description = "Whether the apex A record is proxied (orange cloud). Keep true so Cloudflare fronts the origin."
  default     = true
}

variable "dns_ttl" {
  type        = number
  description = "TTL (seconds) for non-proxied records. Proxied records are forced to automatic (1)."
  default     = 300
}

variable "record_comment" {
  type        = string
  description = "Comment attached to the apex record for auditability."
  default     = "Managed by Terraform (cloudflare component). Points at the network ingress_ip_address."
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
    comment  = optional(string, "Managed by Terraform (cloudflare component).")
  }))
  description = "Arbitrary extra DNS records keyed by a stable logical name (e.g. MX/TXT/SPF/DKIM/DMARC/verification). Only proxiable types should set proxied = true."
  default     = {}
}

variable "caa_records" {
  type = list(object({
    flags = optional(number, 0)
    tag   = string # issue | issuewild | iodef
    value = string
  }))
  description = "CAA records restricting which CAs may issue certificates for the zone. Empty by default (leave unset unless you know the exact CA set, since a wrong CAA blocks edge cert issuance)."
  default     = []
}

# ===========================================================================
# Zone settings (all Free-plan safe)
# ===========================================================================
variable "ssl_mode" {
  type        = string
  description = "Cloudflare SSL/TLS mode. 'strict' = Full (Strict)."
  default     = "strict"

  validation {
    condition     = contains(["strict", "full", "flexible", "off"], var.ssl_mode)
    error_message = "ssl_mode must be one of: strict, full, flexible, off."
  }
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

  validation {
    condition     = contains(["1.0", "1.1", "1.2", "1.3"], var.min_tls_version)
    error_message = "min_tls_version must be one of: 1.0, 1.1, 1.2, 1.3."
  }
}

variable "tls_1_3" {
  type        = string
  description = "Enable TLS 1.3 ('on'/'off'/'zrt')."
  default     = "on"
}

variable "automatic_https_rewrites" {
  type        = string
  description = "Rewrite http:// links to https:// in served HTML ('on'/'off')."
  default     = "on"
}

variable "opportunistic_encryption" {
  type        = string
  description = "Advertise HTTP/2 over TLS to capable clients ('on'/'off')."
  default     = "on"
}

variable "http3" {
  type        = string
  description = "Enable HTTP/3 (QUIC) ('on'/'off')."
  default     = "on"
}

variable "zero_rtt" {
  type        = string
  description = "Enable 0-RTT connection resumption ('on'/'off')."
  default     = "on"
}

variable "brotli" {
  type        = string
  description = "Enable Brotli compression ('on'/'off')."
  default     = "on"
}

variable "websockets" {
  type        = string
  description = "Allow WebSocket connections through the edge ('on'/'off'). Mattermost needs this."
  default     = "on"
}

variable "ipv6" {
  type        = string
  description = "Enable IPv6 at the edge ('on'/'off')."
  default     = "on"
}

variable "security_level" {
  type        = string
  description = "Cloudflare security level (off/essentially_off/low/medium/high/under_attack)."
  default     = "medium"
}

variable "browser_check" {
  type        = string
  description = "Evaluate HTTP headers for common threats ('on'/'off')."
  default     = "on"
}

variable "email_obfuscation" {
  type        = string
  description = "Obfuscate email addresses in served HTML ('on'/'off')."
  default     = "on"
}

variable "challenge_ttl" {
  type        = number
  description = "Seconds a visitor stays allowed after passing a challenge."
  default     = 1800
}

variable "hsts" {
  type = object({
    enabled            = optional(bool, true)
    max_age            = optional(number, 31536000) # 1 year
    include_subdomains = optional(bool, true)
    preload            = optional(bool, true)
    nosniff            = optional(bool, true)
  })
  description = "HTTP Strict Transport Security (security_header). Enabled with a 1-year max-age by default."
  default     = {}
}

variable "dnssec_enabled" {
  type        = bool
  description = "Activate DNSSEC for the zone. After enabling, publish the returned DS record at the registrar to complete the chain."
  default     = true
}

# ===========================================================================
# WAF / rules
# ===========================================================================
variable "custom_firewall_rules" {
  type = list(object({
    expression  = string
    action      = string # block | challenge | managed_challenge | js_challenge | skip | log
    description = string
    enabled     = optional(bool, true)
  }))
  description = "WAF custom rules (Cloudflare Ruleset, http_request_firewall_custom). Available on Free with a limited rule count. No ruleset is created when empty."
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
    action              = string # block | challenge | managed_challenge | js_challenge | log
    description         = string
    period              = number
    requests_per_period = number
    mitigation_timeout  = number
    characteristics     = list(string)
  }))
  description = "Rate limiting rules (Cloudflare Ruleset, http_ratelimit). PAID/advanced; leave empty on Free. No ruleset is created when empty."
  default     = []
}

# ===========================================================================
# Origin TLS (optional, default off)
# ===========================================================================
variable "manage_origin_cert" {
  type        = bool
  description = "Issue a Cloudflare Origin CA certificate from Terraform (served by the GKE ingress for Full (Strict) TLS). On by default so the strict SSL mode has a matching origin cert. Requires the API token to carry SSL and Certificates: Edit; the cert PEM + key are exposed as (sensitive) outputs to load into the platform mattermost-origin-tls-* secrets."
  default     = true
}

variable "origin_cert_hostnames" {
  type        = list(string)
  description = "Extra hostnames to include on the Origin CA certificate (the apex and *.apex are always included)."
  default     = []
}

variable "origin_cert_validity_days" {
  type        = number
  description = "Requested validity for the Origin CA certificate (days). Cloudflare accepts 7, 30, 90, 365, 730, 1095, 5475."
  default     = 5475
}

variable "aop_enabled" {
  type        = bool
  description = "Enable per-hostname Authenticated Origin Pulls (edge presents a client cert to the origin). Requires aop_certificate/aop_private_key. Off by default."
  default     = false
}

variable "aop_certificate" {
  type        = string
  description = "PEM client certificate the Cloudflare edge presents to the origin (per-hostname AOP)."
  default     = ""
}

variable "aop_private_key" {
  type        = string
  sensitive   = true
  description = "PEM private key for the AOP client certificate."
  default     = ""
}
