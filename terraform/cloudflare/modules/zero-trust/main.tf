# Zero Trust access to private in-cluster services: client -> Access policy
# (allowed emails) -> Cloudflare Tunnel (outbound-only cloudflared pod) ->
# ClusterIP, no public exposure. Requires an ACCOUNT-scoped API token
# (Cloudflare Tunnel:Edit + Access: Apps and Policies:Edit + Access: Service
# Tokens:Edit + MCP Portals:Edit).
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

  # The official Terraform MCP does not publish human-readable Tool.title
  # metadata. Keep its stable protocol names, but give Portal users enough
  # context to distinguish Registry discovery, HCP workspaces and Stack runs.
  # Personal WhatsApp aliases also provide a deterministic display fallback
  # for Portal clients that do not preserve the upstream Tool.title field.
  mcp_tool_aliases = {
    terraform = {
      attach_policy_set_to_workspaces     = "HCP Terraform · Policy sets · Attach to workspaces"
      attach_variable_set_to_workspaces   = "HCP Terraform · Variable sets · Attach to workspaces"
      create_no_code_workspace            = "HCP Terraform · Workspaces · Create no-code workspace"
      create_run                          = "HCP Terraform · Runs · Create"
      create_variable_in_variable_set     = "HCP Terraform · Variable sets · Create variable"
      create_variable_set                 = "HCP Terraform · Variable sets · Create"
      create_workspace                    = "HCP Terraform · Workspaces · Create"
      create_workspace_tags               = "HCP Terraform · Workspaces · Add tags"
      create_workspace_variable           = "HCP Terraform · Workspaces · Create variable"
      delete_variable_in_variable_set     = "HCP Terraform · Variable sets · Delete variable"
      detach_variable_set_from_workspaces = "HCP Terraform · Variable sets · Detach from workspaces"
      get_apply_details                   = "HCP Terraform · Applies · Get details"
      get_apply_logs                      = "HCP Terraform · Applies · Get logs"
      get_latest_module_version           = "Terraform Registry · Modules · Get latest version"
      get_latest_provider_version         = "Terraform Registry · Providers · Get latest version"
      get_module_details                  = "Terraform Registry · Modules · Get details"
      get_plan_details                    = "HCP Terraform · Plans · Get details"
      get_plan_json_output                = "HCP Terraform · Plans · Get JSON output"
      get_plan_logs                       = "HCP Terraform · Plans · Get logs"
      get_policy_details                  = "Terraform Registry · Policies · Get details"
      get_provider_capabilities           = "Terraform Registry · Providers · Get capabilities"
      get_provider_details                = "Terraform Registry · Providers · Get details"
      get_run_details                     = "HCP Terraform · Runs · Get details"
      get_stack_details                   = "HCP Terraform · Stacks · Get details"
      get_token_permissions               = "HCP Terraform · Account · Get token permissions"
      get_workspace_details               = "HCP Terraform · Workspaces · Get details"
      list_runs                           = "HCP Terraform · Runs · List"
      list_stacks                         = "HCP Terraform · Stacks · List"
      list_terraform_orgs                 = "HCP Terraform · Organizations · List"
      list_terraform_projects             = "HCP Terraform · Projects · List"
      list_variable_sets                  = "HCP Terraform · Variable sets · List"
      list_workspace_policy_sets          = "HCP Terraform · Workspaces · List policy sets"
      list_workspace_variables            = "HCP Terraform · Workspaces · List variables"
      list_workspaces                     = "HCP Terraform · Workspaces · List"
      read_workspace_tags                 = "HCP Terraform · Workspaces · List tags"
      search_modules                      = "Terraform Registry · Modules · Search"
      search_policies                     = "Terraform Registry · Policies · Search"
      search_providers                    = "Terraform Registry · Providers · Search"
      update_workspace                    = "HCP Terraform · Workspaces · Update"
      update_workspace_variable           = "HCP Terraform · Workspaces · Update variable"
    }
    whatsapp-personal = {
      whatsapp_personal_status             = "WhatsApp Personal · Session · Status"
      whatsapp_personal_get_qr             = "WhatsApp Personal · Session · Get QR code"
      whatsapp_personal_list_conversations = "WhatsApp Personal · Messages · List conversations"
      whatsapp_personal_list_messages      = "WhatsApp Personal · Messages · List"
      whatsapp_personal_send_text          = "WhatsApp Personal · Messages · Send text"
      whatsapp_personal_mark_read          = "WhatsApp Personal · Messages · Mark read"
      whatsapp_personal_emergency_stop     = "WhatsApp Personal · Session · Emergency stop"
      whatsapp_personal_resume             = "WhatsApp Personal · Session · Resume"
      whatsapp_personal_reset_link         = "WhatsApp Personal · Session · Reset linked device"
    }
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
  account_id         = var.account_id
  id                 = "yourown-chat"
  name               = "yourown-chat"
  description        = "Curated MCP access for yourown-chat agents"
  hostname           = "mcp.${var.domain}"
  allow_code_mode    = true
  secure_web_gateway = false

  servers = [for label, server in cloudflare_zero_trust_access_ai_controls_mcp_server.this : {
    server_id        = server.id
    default_disabled = false
    # Use the server's Access service token. Per-user upstream authorization is
    # redundant: Google Cloud and Terraform already use shared workload
    # credentials after the MCP request reaches the cluster.
    on_behalf = false
    updated_tools = [
      for name, alias in lookup(
        local.mcp_tool_aliases,
        trimprefix(label, "mcp-"),
        {},
        ) : {
        name    = name
        alias   = alias
        enabled = true
      }
    ]
  }]
}

# The Portal API does not create DNS when called by Terraform.
resource "cloudflare_dns_record" "mcp_portal" {
  zone_id = var.zone_id
  name    = "mcp"
  type    = "CNAME"
  content = "gateway.agents.cloudflare.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare MCP Portal (Managed by Terraform)."
}
