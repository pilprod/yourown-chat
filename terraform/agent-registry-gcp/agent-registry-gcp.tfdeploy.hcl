# Google Cloud Agent Registry governance catalog. Apply platform-gcp first so
# the API is enabled, then this independent provider-specific stack. It
# deliberately has no linked-stack values: all registered interfaces are
# stable public endpoints.

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"

  gcp_project = "yourown-chat"
  gcp_region  = "europe-west3"
}

identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

deployment "eu" {
  inputs = {
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa

    project_id = local.gcp_project
    region     = local.gcp_region

    endpoints = {
      mattermost-api = {
        display_name = "Mattermost API"
        description  = "Production Mattermost REST API used by agent integrations."
        url          = "https://yourown.chat/api/v4"
      }
      hcp-terraform-api = {
        display_name = "HCP Terraform API"
        description  = "HCP Terraform v2 API used through the Terraform MCP server."
        url          = "https://app.terraform.io/api/v2"
      }
      meta-graph-api = {
        display_name = "Meta Graph API"
        description  = "Official Meta Graph API used by the WhatsApp Business MCP adapter and future Messenger/Instagram tools."
        url          = "https://graph.facebook.com/v23.0"
      }
    }

    external_mcp_servers = {
      meta-developer-tools = {
        display_name = "Meta Developer Tools MCP"
        description  = "Official Meta MCP for app configuration, diagnostics, review, compliance, documentation, and webhook administration."
        url          = "https://mcp.facebook.com/devtools"
      }
    }
  }
}

publish_output "endpoint_resource_names" {
  description = "Registered external Agent Registry Endpoint resources."
  value       = deployment.eu.endpoint_resource_names
}

publish_output "external_mcp_resource_names" {
  description = "Registered vendor-hosted MCP Server resources."
  value       = deployment.eu.external_mcp_resource_names
}
