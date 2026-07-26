# Zero Trust access to private in-cluster services: client -> Access policy
# (allowed emails) -> Cloudflare Tunnel (outbound-only cloudflared pod) ->
# ClusterIP, no public exposure. Requires an ACCOUNT-scoped API token
# (Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit + Access: Service
# Tokens:Edit + MCP Portals:Edit + Workers Scripts:Edit + Workers KV
# Storage:Edit + Workers Routes:Edit).
# The sibling zero-trust-organization component additionally needs Access:
# Organizations, Identity Providers, and Groups:Edit.

# config_src = "cloudflare": ingress rules are pushed from here; the pod just
# runs `tunnel run`.
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id    = var.account_id
  name          = "yourown-chat-private"
  tunnel_secret = random_id.tunnel_secret.b64_std
  config_src    = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# hostname -> in-cluster service URL; a catch-all 404 closes everything else.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config = {
    ingress = concat(
      [for label, service in var.upstreams : {
        hostname = "${label}.${var.domain}"
        service  = service
      }],
      [for label, upstream in var.public_upstreams : {
        hostname = "${label}.${var.domain}"
        path     = upstream.path
        service  = upstream.service
      }],
      [{ service = "http_status:404" }]
    )
  }
}

# Proxied DNS onto the tunnel (no origin IP; points at cfargotunnel.com).
resource "cloudflare_dns_record" "this" {
  for_each = var.upstreams

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Private service behind Cloudflare Tunnel + Access (Managed by Terraform)."
}

resource "cloudflare_dns_record" "public_webhook" {
  for_each = var.public_upstreams

  zone_id = var.zone_id
  name    = each.key
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "Signed public webhook behind Cloudflare Tunnel (Managed by Terraform)."
}

locals {
  mcp_upstreams = {
    for label, service in var.upstreams : label => service
    if startswith(label, "mcp-")
  }
}

# One machine identity lets AI Controls synchronize and invoke every currently
# registered upstream. End-user clients never receive these credentials.
# Split this into one token and policy per server when the MCP role model is
# introduced.
resource "cloudflare_zero_trust_access_service_token" "ai_controls" {
  account_id = var.account_id
  name       = "yourown-chat AI Controls MCP upstreams"
  duration   = var.mcp_service_token_duration

  lifecycle {
    create_before_destroy = true
  }
}

# Access application + inline allow-list policy per hostname. Provider v5 no
# longer manages application-scoped policies as standalone resources.
resource "cloudflare_zero_trust_access_application" "this" {
  for_each = var.upstreams

  account_id       = var.account_id
  name             = each.key
  domain           = "${each.key}.${var.domain}"
  type             = "self_hosted"
  session_duration = var.session_duration

  policies = concat(
    startswith(each.key, "mcp-") ? [{
      name       = "ai-controls-service-token"
      precedence = 1
      decision   = "non_identity"
      include = [{
        service_token = {
          token_id = cloudflare_zero_trust_access_service_token.ai_controls.id
        }
      }]
    }] : [],
    [{
      name       = "allowed-emails"
      precedence = startswith(each.key, "mcp-") ? 2 : 1
      decision   = "allow"
      include    = [for email in var.allowed_emails : { email = { email = email } }]
    }]
  )
}

# AI Controls catalog entry for every public MCP origin. Cloudflare stores one
# Access service-token credential for capability synchronization and shared
# Portal access. End users authenticate only to the Portal and never receive
# or handle this machine credential.
resource "cloudflare_zero_trust_access_ai_controls_mcp_server" "this" {
  for_each = local.mcp_upstreams

  account_id  = var.account_id
  id          = trimprefix(each.key, "mcp-")
  name        = each.key
  description = "yourown-chat ${each.key} MCP server"
  hostname    = "https://${each.key}.${var.domain}/mcp"
  auth_type   = "bearer"
  auth_credentials = jsonencode({
    headers = {
      "CF-Access-Client-Id"     = cloudflare_zero_trust_access_service_token.ai_controls.client_id
      "CF-Access-Client-Secret" = cloudflare_zero_trust_access_service_token.ai_controls.client_secret
    }
  })
  is_shared_oauth_callback_enabled = false
  secure_web_gateway               = false
}

# A dedicated type=mcp Access application controls which authenticated users
# can discover each server through a portal. It is separate from the
# self_hosted application that protects the server's direct URL.
resource "cloudflare_zero_trust_access_application" "mcp_server" {
  for_each = local.mcp_upstreams

  account_id = var.account_id
  name       = "${each.key}-portal-policy"
  type       = "mcp"
  destinations = [{
    type          = "via_mcp_server_portal"
    mcp_server_id = cloudflare_zero_trust_access_ai_controls_mcp_server.this[each.key].id
  }]

  policies = [{
    name       = "allowed-emails"
    precedence = 1
    decision   = "allow"
    include    = [for email in var.allowed_emails : { email = { email = email } }]
  }]
}

resource "cloudflare_zero_trust_access_ai_controls_mcp_portal" "this" {
  account_id  = var.account_id
  id          = "yourown-chat"
  name        = "yourown-chat"
  description = "Curated MCP access for yourown-chat agents"
  # The Portal is an origin behind the stable OAuth compatibility Worker.
  # End-user clients continue using https://mcp.<domain>/mcp.
  hostname           = "mcp-origin.${var.domain}"
  allow_code_mode    = true
  secure_web_gateway = false

  servers = [for server in cloudflare_zero_trust_access_ai_controls_mcp_server.this : {
    server_id        = server.id
    default_disabled = false
    # Use the server's Access service token. Per-user upstream authorization is
    # redundant: Google Cloud and Terraform already use shared workload
    # credentials after the MCP request reaches the cluster.
    on_behalf = false
  }]
}

# The Portal API does not create DNS when called by Terraform. The origin is
# never presented to clients and accepts only the Worker's service token.
resource "cloudflare_dns_record" "mcp_portal_origin" {
  zone_id = var.zone_id
  name    = "mcp-origin"
  type    = "CNAME"
  content = "gateway.agents.cloudflare.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare MCP Portal origin behind OAuth compatibility Worker (Managed by Terraform)."
}

# Keep the public endpoint stable. A Worker route intercepts this hostname
# before the CNAME fallback reaches the Portal origin.
resource "cloudflare_dns_record" "mcp_portal" {
  zone_id = var.zone_id
  name    = "mcp"
  type    = "CNAME"
  content = "mcp-origin.${var.domain}"
  proxied = true
  ttl     = 1
  comment = "Stable MCP OAuth compatibility endpoint (Managed by Terraform)."
}

# Access for SaaS authenticates the operator once during authorization. The
# Worker then issues and refreshes its own MCP-bound tokens; no upstream Access
# refresh token is stored in the client grant.
resource "cloudflare_zero_trust_access_application" "mcp_oauth_identity" {
  account_id           = var.account_id
  name                 = "yourown-chat MCP OAuth identity"
  type                 = "saas"
  app_launcher_visible = false
  session_duration     = var.session_duration

  saas_app = {
    auth_type                        = "oidc"
    allow_pkce_without_client_secret = false
    grant_types                      = ["authorization_code_with_pkce"]
    redirect_uris                    = ["https://mcp.${var.domain}/callback"]
    scopes                           = ["openid", "email", "profile"]
  }

  policies = [{
    name       = "allowed-emails"
    precedence = 1
    decision   = "allow"
    include    = [for email in var.allowed_emails : { email = { email = email } }]
  }]

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_workers_kv_namespace" "mcp_oauth" {
  account_id = var.account_id
  title      = "yourown-chat-mcp-oauth"
}

resource "random_id" "mcp_oauth_state_secret" {
  byte_length = 32
}

locals {
  mcp_oauth_worker_name = "yourown-chat-mcp-oauth"
  mcp_oauth_worker_file = abspath("${path.module}/../../../../workers/mcp-oauth-proxy/dist/worker.js")
  mcp_oauth_issuer      = "https://${var.team_name}.cloudflareaccess.com/cdn-cgi/access/sso/oidc/${cloudflare_zero_trust_access_application.mcp_oauth_identity.saas_app.client_id}"
}

resource "cloudflare_workers_script" "mcp_oauth" {
  account_id     = var.account_id
  script_name    = local.mcp_oauth_worker_name
  content_file   = local.mcp_oauth_worker_file
  content_sha256 = filesha256(local.mcp_oauth_worker_file)
  main_module    = "worker.js"

  compatibility_date = "2026-07-26"
  compatibility_flags = [
    "global_fetch_strictly_public",
    "nodejs_compat",
  ]

  bindings = [
    {
      name         = "OAUTH_KV"
      type         = "kv_namespace"
      namespace_id = cloudflare_workers_kv_namespace.mcp_oauth.id
    },
    {
      name = "ACCESS_CLIENT_ID"
      type = "plain_text"
      text = cloudflare_zero_trust_access_application.mcp_oauth_identity.saas_app.client_id
    },
    {
      name = "ACCESS_CLIENT_SECRET"
      type = "secret_text"
      text = cloudflare_zero_trust_access_application.mcp_oauth_identity.saas_app.client_secret
    },
    {
      name = "ACCESS_ISSUER"
      type = "plain_text"
      text = local.mcp_oauth_issuer
    },
    {
      name = "ACCESS_AUTHORIZATION_URL"
      type = "plain_text"
      text = "${local.mcp_oauth_issuer}/authorization"
    },
    {
      name = "ACCESS_TOKEN_URL"
      type = "plain_text"
      text = "${local.mcp_oauth_issuer}/token"
    },
    {
      name = "ACCESS_JWKS_URL"
      type = "plain_text"
      text = "${local.mcp_oauth_issuer}/jwks"
    },
    {
      name = "ALLOWED_EMAILS"
      type = "plain_text"
      text = jsonencode(var.allowed_emails)
    },
    {
      name = "OAUTH_STATE_SECRET"
      type = "secret_text"
      text = random_id.mcp_oauth_state_secret.hex
    },
    {
      name = "PORTAL_ORIGIN_URL"
      type = "plain_text"
      text = "https://${cloudflare_zero_trust_access_ai_controls_mcp_portal.this.hostname}/mcp"
    },
    {
      name = "PORTAL_SERVICE_TOKEN_ID"
      type = "secret_text"
      text = cloudflare_zero_trust_access_service_token.ai_controls.client_id
    },
    {
      name = "PORTAL_SERVICE_TOKEN_SECRET"
      type = "secret_text"
      text = cloudflare_zero_trust_access_service_token.ai_controls.client_secret
    },
  ]

  observability = {
    enabled = true
    logs = {
      enabled            = true
      invocation_logs    = true
      head_sampling_rate = 1
      persist            = true
    }
  }
}

resource "cloudflare_workers_route" "mcp_oauth" {
  zone_id = var.zone_id
  pattern = "mcp.${var.domain}/*"
  script  = cloudflare_workers_script.mcp_oauth.script_name
}

resource "cloudflare_workers_cron_trigger" "mcp_oauth_cleanup" {
  account_id  = var.account_id
  script_name = cloudflare_workers_script.mcp_oauth.script_name
  schedules = [{
    cron = "17 * * * *"
  }]
}
