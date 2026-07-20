# Cloudflare stack outputs — the human surface. All are gated with one([...])
# because the components only exist when public_ingress_enabled = true.

output "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare zone ID for the managed domain."
  value       = one([for c in component.cloudflare : c.zone_id])
}

output "cloudflare_record_hostname" {
  type        = string
  description = "Fully-qualified hostname of the proxied apex A record."
  value       = one([for c in component.cloudflare : c.record_hostname])
}

output "cloudflare_origin_ip" {
  type        = string
  description = "IPv4 the proxied apex A record points at (echoes the platform ingress IP)."
  value       = one([for c in component.cloudflare : c.origin_ip])
}

output "cloudflare_dnssec" {
  type = object({
    status      = string
    ds          = string
    digest      = string
    key_tag     = string
    algorithm   = string
    digest_type = string
  })
  description = "DNSSEC DS material to publish at the registrar (null when dnssec disabled or no public ingress)."
  value       = one([for c in component.cloudflare : c.dnssec])
}

# --- Origin-protection secrets ------------------------------------------------
output "origin_secret_ids" {
  type        = map(string)
  description = "Logical name => Secret Manager secret ID for the origin-protection secret CONTAINERS (mattermost-origin-tls-cert/-key + cloudflare-origin-pull-ca). Informational; empty map when public_ingress_enabled = false. Do NOT derive an on/off toggle from its length -- the pull-ca container is always present even without a value; use origin_tls_ready for that."
  # Empty map (not null) when origin_secrets is absent, so length()/keys() on a
  # downstream consumer never hit a null.
  value = length(component.origin_secrets) > 0 ? one([for s in component.origin_secrets : s.secret_ids]) : {}
}

# Precise readiness signal for the origin-TLS material, so a downstream stack can
# turn its origin-TLS Secret ON exactly when the cert/key EXIST -- no hand-kept
# mirror toggle. Keyed off secret_version_ids (versions are created only for
# value-bearing secrets), NOT the always-present containers, so a cert-less
# public edge (manage_origin_cert = false) does not falsely enable it. True iff
# public_ingress_enabled AND manage_origin_cert. Non-sensitive: it inspects a
# key NAME, never the cert bytes. app-gcp links this stack and derives
# manage_ingress_origin_tls = this.
output "origin_tls_ready" {
  type        = bool
  description = "True when the Cloudflare Origin CA cert/key Secret Manager versions exist (public_ingress_enabled AND manage_origin_cert). app-gcp derives manage_ingress_origin_tls from it."
  value = length(component.origin_secrets) > 0 ? contains(
    keys(one([for s in component.origin_secrets : s.secret_version_ids])),
    "mattermost-origin-tls-cert"
  ) : false
}
