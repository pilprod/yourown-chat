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

  # Cloudflare aliases are protocol identifiers rather than free-form titles:
  # they accept only alphanumeric sections separated by "_" or "-" and are
  # limited to 40 characters. The Portal already prefixes the server name, so
  # aliases add only the missing product/domain context and avoid duplication.
  mcp_tool_aliases = {
    terraform = {
      attach_policy_set_to_workspaces     = "hcp_policy_sets_attach"
      attach_variable_set_to_workspaces   = "hcp_variable_sets_attach"
      create_no_code_workspace            = "hcp_workspaces_create_no_code"
      create_run                          = "hcp_runs_create"
      create_variable_in_variable_set     = "hcp_variable_sets_variable_create"
      create_variable_set                 = "hcp_variable_sets_create"
      create_workspace                    = "hcp_workspaces_create"
      create_workspace_tags               = "hcp_workspaces_tags_add"
      create_workspace_variable           = "hcp_workspaces_variable_create"
      delete_variable_in_variable_set     = "hcp_variable_sets_variable_delete"
      detach_variable_set_from_workspaces = "hcp_variable_sets_detach"
      get_apply_details                   = "hcp_applies_get"
      get_apply_logs                      = "hcp_applies_logs_get"
      get_latest_module_version           = "registry_modules_latest"
      get_latest_provider_version         = "registry_providers_latest"
      get_module_details                  = "registry_modules_get"
      get_plan_details                    = "hcp_plans_get"
      get_plan_json_output                = "hcp_plans_json_get"
      get_plan_logs                       = "hcp_plans_logs_get"
      get_policy_details                  = "registry_policies_get"
      get_provider_capabilities           = "registry_providers_capabilities"
      get_provider_details                = "registry_providers_get"
      get_run_details                     = "hcp_runs_get"
      get_stack_details                   = "hcp_stacks_get"
      get_token_permissions               = "hcp_account_token_permissions_get"
      get_workspace_details               = "hcp_workspaces_get"
      list_runs                           = "hcp_runs_list"
      list_stacks                         = "hcp_stacks_list"
      list_terraform_orgs                 = "hcp_organizations_list"
      list_terraform_projects             = "hcp_projects_list"
      list_variable_sets                  = "hcp_variable_sets_list"
      list_workspace_policy_sets          = "hcp_workspaces_policy_sets_list"
      list_workspace_variables            = "hcp_workspaces_variables_list"
      list_workspaces                     = "hcp_workspaces_list"
      read_workspace_tags                 = "hcp_workspaces_tags_list"
      search_modules                      = "registry_modules_search"
      search_policies                     = "registry_policies_search"
      search_providers                    = "registry_providers_search"
      update_workspace                    = "hcp_workspaces_update"
      update_workspace_variable           = "hcp_workspaces_variable_update"
    }
    whatsapp-personal = {
      whatsapp_personal_status             = "session_status"
      whatsapp_personal_get_qr             = "session_qr_get"
      whatsapp_personal_list_conversations = "messages_conversations_list"
      whatsapp_personal_list_messages      = "messages_list"
      whatsapp_personal_send_text          = "messages_text_send"
      whatsapp_personal_mark_read          = "messages_mark_read"
      whatsapp_personal_emergency_stop     = "session_emergency_stop"
      whatsapp_personal_resume             = "session_resume"
      whatsapp_personal_reset_link         = "session_link_reset"
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
  account_id  = var.account_id
  id          = "yourown-chat"
  name        = "yourown-chat"
  description = "Curated MCP access for yourown-chat agents"
  # `tools` describes the stable public contract: this endpoint exposes tools
  # to humans and agents. Reserve `agents` for the future Mattermost/Temporal
  # agent control plane and avoid the visually duplicated mcp.<domain>/mcp.
  hostname           = "${var.mcp_portal_subdomain}.${var.domain}"
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

  lifecycle {
    # The Portal holds the client-facing OAuth contract. Hostname changes must
    # be supported in place by Cloudflare; never silently replace the Portal
    # and invalidate every registered client/grant.
    prevent_destroy = true
  }
}

# The Portal API does not create DNS when called by Terraform.
resource "cloudflare_dns_record" "mcp_portal" {
  zone_id = var.zone_id
  name    = var.mcp_portal_subdomain
  type    = "CNAME"
  content = "gateway.agents.cloudflare.com"
  proxied = true
  ttl     = 1
  comment = "Cloudflare MCP Portal (Managed by Terraform)."

  lifecycle {
    # A DNS label rename is expected to be an in-place provider update. Stop
    # the plan if the provider ever models it as delete/create.
    prevent_destroy = true
  }
}
