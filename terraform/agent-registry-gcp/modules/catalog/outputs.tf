output "endpoint_resource_names" {
  description = "Logical endpoint ID to generated read-only Endpoint resource."
  value = {
    for id, service in google_agent_registry_service.endpoint :
    id => service.registry_resource
  }
}

output "external_mcp_resource_names" {
  description = "Logical MCP ID to generated read-only MCP Server resource."
  value = {
    for id, service in google_agent_registry_service.mcp_server :
    id => service.registry_resource
  }
}
