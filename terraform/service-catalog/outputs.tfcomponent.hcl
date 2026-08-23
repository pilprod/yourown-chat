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

output "kagent_testbed" {
  type = object({
    enabled                       = bool
    candidate_tag                 = string
    product_commit               = string
    chart_repository             = string
    chart_version                = string
    source_commit                = string
    application_chart_oci_digest = string
    crd_chart_oci_digest         = string
    application_values_sha256    = string
    crd_values_sha256            = string
    namespace                    = string
    workload_namespace           = string
    ui_hostname                  = string
    ui_service                   = string
  })
  description = "Pinned stock Kagent testbed release contract."
  value       = var.kagent_testbed
}

output "private_upstreams" {
  type        = map(string)
  description = "Private Access/Tunnel upstream assignments."
  value       = var.private_upstreams
}
