# GKE-hosted MCP servers are intentionally absent here: their production
# Deployments carry the GKE discovery metadata and Agent Registry introspects
# them automatically. Official Google remote MCP servers are also registered
# automatically when their APIs are enabled by platform-gcp.

component "catalog" {
  source = "./modules/catalog"

  inputs = {
    project_id           = var.project_id
    location             = var.region
    endpoints            = var.endpoints
    external_mcp_servers = var.external_mcp_servers
  }

  providers = {
    google = provider.google.this
  }
}
