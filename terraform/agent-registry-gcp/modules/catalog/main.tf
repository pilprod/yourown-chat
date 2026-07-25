resource "google_agent_registry_service" "endpoint" {
  for_each = var.endpoints

  project      = var.project_id
  location     = var.location
  service_id   = each.key
  display_name = each.value.display_name
  description  = each.value.description

  interfaces {
    url              = each.value.url
    protocol_binding = each.value.protocol_binding
  }

  endpoint_spec {
    type = "NO_SPEC"
  }
}

resource "google_agent_registry_service" "mcp_server" {
  for_each = var.external_mcp_servers

  project      = var.project_id
  location     = var.location
  service_id   = each.key
  display_name = each.value.display_name
  description  = each.value.description

  interfaces {
    url              = each.value.url
    protocol_binding = each.value.protocol_binding
  }

  mcp_server_spec {
    # The Terraform provider registers the endpoint. Tool import/introspection
    # for public third-party MCPs is a separate registry operation.
    type = "NO_SPEC"
  }
}
