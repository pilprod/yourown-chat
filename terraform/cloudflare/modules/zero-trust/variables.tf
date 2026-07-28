variable "account_id" {
  type        = string
  description = "Cloudflare ACCOUNT ID owning the Zero Trust organization (tunnels and Access apps are account-level objects)."

  validation {
    condition     = length(var.account_id) > 0
    error_message = "account_id must not be empty when Zero Trust is enabled."
  }
}

variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID for the DNS records routing hostnames onto the tunnel."
}

variable "domain" {
  type        = string
  description = "Zone apex; each upstream key becomes <key>.<domain>."
}

variable "mcp_portal_subdomain" {
  type        = string
  description = "DNS label used by the shared MCP tool gateway. Keep agents.<domain> available for the future agent control plane."
  default     = "tools"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", var.mcp_portal_subdomain))
    error_message = "mcp_portal_subdomain must be one valid lowercase DNS label."
  }
}

variable "upstreams" {
  type        = map(string)
  description = "Hostname label => private in-cluster service URL (e.g. mcp-terraform-stacks => http://mcp-terraform-stacks.mcp-terraform-stacks.svc.cluster.local:3000). One tunnel ingress rule, DNS record and Access app per entry."

  validation {
    condition     = length(var.upstreams) > 0
    error_message = "Provide at least one upstream when Zero Trust is enabled."
  }
}

variable "public_upstreams" {
  type = map(object({
    service = string
    path    = string
  }))
  description = "Public hostname label => private service URL and anchored path regex. These routes receive no Access application and must verify signed webhook requests at the origin."
  default     = {}

  validation {
    condition = length(setintersection(
      toset(keys(var.public_upstreams)),
      toset(keys(var.upstreams)),
    )) == 0
    error_message = "A hostname cannot be both Access-protected and public."
  }

  validation {
    condition = alltrue([
      for upstream in values(var.public_upstreams) :
      startswith(upstream.path, "^") && endswith(upstream.path, "$")
    ])
    error_message = "Every public upstream path must be an anchored regular expression."
  }
}

variable "allowed_emails" {
  type        = list(string)
  description = "Emails allowed through the Access policy (Zero Trust Free covers 50 users)."

  validation {
    condition     = length(var.allowed_emails) > 0
    error_message = "Provide at least one allowed email -- an empty include list would lock everyone out."
  }
}

variable "session_duration" {
  type        = string
  description = "Access session lifetime before re-authentication."
  default     = "24h"
}

variable "mcp_service_token_duration" {
  type        = string
  description = "Lifetime of the shared AI Controls machine credential used to reach protected MCP upstreams. Rotate before expiry; split per server when fine-grained roles are introduced."
  default     = "8760h"
}
