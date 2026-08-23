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
  description = "Source repositories keyed by role plus a non-repository catalog_contract entry carrying the versioned compatibility envelope."
  value = merge(var.source_repositories, {
    catalog_contract = {
      name = "catalog-contract"
      remote_uri = jsonencode({
        revision                  = var.catalog_revision
        vendor_chart_bundles      = var.vendor_chart_bundles
        additional_database_users = var.additional_database_users
        private_http_routes       = var.private_http_routes
      })
    }
  })
}

output "catalog_revision" {
  type        = string
  description = "Revision marker of the published catalog."
  value       = var.catalog_revision
}

output "vendor_chart_bundles" {
  type = map(object({
    provisioned              = bool
    application_enabled      = bool
    deployment_class         = string
    production_eligible      = bool
    candidate_tag            = string
    product_commit           = string
    source_commit            = string
    supported_agent_runtimes = set(string)
    image_digests            = map(string)
    charts = object({
      crds = object({
        release_name  = string
        ref           = string
        version       = string
        values_base64 = string
        values_sha256 = string
      })
      application = object({
        release_name  = string
        ref           = string
        version       = string
        values_base64 = string
        values_sha256 = string
      })
    })
    namespaces = map(object({
      name          = string
      quota_profile = string
    }))
    endpoints = map(object({
      namespace_key = string
      pod_selector  = map(string)
    }))
    external_sources = map(object({
      namespace    = string
      pod_selector = map(string)
    }))
    flows = map(object({
      source_kind     = string
      source_key      = string
      destination_key = string
      ports = set(object({
        port     = number
        protocol = string
      }))
    }))
    kubernetes_api_egress_from = set(string)
    database_bindings = map(object({
      source_endpoint_key   = string
      secret_id_key         = string
      secret_provider_class = string
      secret_file           = string
      port                  = number
    }))
  }))
  description = "Immutable vendor OCI chart bundles with typed placement and network bindings."
  value       = var.vendor_chart_bundles
}

output "additional_database_users" {
  type = map(object({
    database_names              = set(string)
    password_secret_id          = string
    connection_secret_id        = optional(string)
    password_rotation           = optional(string, "1")
    manage_databases            = optional(bool, true)
    connection_secret_accessors = optional(set(string), [])
    kubernetes_connection_secret_accessors = optional(set(object({
      namespace       = string
      service_account = string
    })), [])
  }))
  description = "Additional logical Cloud SQL database/user requests."
  value       = var.additional_database_users
}

output "private_http_routes" {
  type = map(object({
    enabled   = bool
    namespace = string
    service   = string
    port      = number
  }))
  description = "Typed private Access/Tunnel HTTP routes."
  value       = var.private_http_routes
}
