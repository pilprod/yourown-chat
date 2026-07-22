# Zero Trust access to private in-cluster services: client -> Access policy
# (allowed emails) -> Cloudflare Tunnel (outbound-only cloudflared pod) ->
# ClusterIP, no public exposure. Requires an ACCOUNT-scoped API token
# (Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit).

# config_src = "cloudflare": ingress rules are pushed from here; the pod just
# runs `tunnel run`.
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = "yourown-chat-private"
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

# hostname -> in-cluster service URL; a catch-all 404 closes everything else.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config {
    dynamic "ingress_rule" {
      for_each = var.upstreams
      content {
        hostname = "${ingress_rule.key}.${var.domain}"
        service  = ingress_rule.value
      }
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# Proxied DNS onto the tunnel (no origin IP; points at cfargotunnel.com).
resource "cloudflare_record" "this" {
  for_each = var.upstreams

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Private service behind Cloudflare Tunnel + Access (Managed by Terraform)."
}

# Access application + allow-list policy per hostname: only the listed emails
# pass the edge (checked before the request reaches the tunnel).
resource "cloudflare_zero_trust_access_application" "this" {
  for_each = var.upstreams

  account_id       = var.account_id
  name             = each.key
  domain           = "${each.key}.${var.domain}"
  type             = "self_hosted"
  session_duration = var.session_duration
}

resource "cloudflare_zero_trust_access_policy" "allow" {
  for_each = var.upstreams

  account_id     = var.account_id
  application_id = cloudflare_zero_trust_access_application.this[each.key].id
  name           = "allowed-emails"
  precedence     = 1
  decision       = "allow"

  include {
    email = var.allowed_emails
  }
}
