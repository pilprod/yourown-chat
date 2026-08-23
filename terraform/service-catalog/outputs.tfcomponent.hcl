# Deployment outputs republished below as the cross-stack contract.
output "github_connection_name" {
  type        = string
  description = "Cloud Build 2nd-gen GitHub connection name."
  value       = var.github_connection_name
}

output "source_repositories" {
  type = map(object({
    name       = string
    remote_uri = string
  }))
  description = "Source repositories keyed by role."
  value       = var.source_repositories
}

output "catalog_revision" {
  type        = string
  description = "Revision marker of the published catalog."
  value       = var.catalog_revision
}

output "vendor_chart_bundles" {
  description = "Immutable vendor OCI chart bundles with typed placement and network bindings."
  value       = var.vendor_chart_bundles
}

output "additional_database_users" {
  description = "Additional logical Cloud SQL database/user requests."
  value       = var.additional_database_users
}

output "private_http_routes" {
  description = "Typed private Access/Tunnel HTTP routes."
  value       = var.private_http_routes
}
