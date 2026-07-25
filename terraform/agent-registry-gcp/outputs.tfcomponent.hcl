output "endpoint_resource_names" {
  type        = map(string)
  description = "Logical endpoint ID to generated read-only Agent Registry Endpoint resource."
  value       = component.catalog.endpoint_resource_names
}

output "external_mcp_resource_names" {
  type        = map(string)
  description = "Logical MCP ID to generated read-only Agent Registry MCP Server resource."
  value       = component.catalog.external_mcp_resource_names
}
