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
