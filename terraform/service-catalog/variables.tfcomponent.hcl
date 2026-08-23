# Private service catalog inputs. Values live only in this private repository's
# deployment file and in the Stack's last-applied outputs; the public platform
# Stacks consume them through upstream_input and never define them.
variable "github_connection_name" {
  type        = string
  description = "Name of the existing Cloud Build 2nd-gen GitHub connection every source repository is linked to."
}

variable "source_repositories" {
  type = map(object({
    name       = string
    remote_uri = string
  }))
  description = "Source repositories keyed by role (deploy, mattermost, web, server_source, backend, agents, mcp, rtcd). `name` is the Cloud Build 2nd-gen repository resource name; `remote_uri` is the HTTPS clone URL."
}

variable "catalog_revision" {
  type        = string
  description = "Human-readable revision marker of the catalog contents. Changing it forces a changed apply so the published values propagate to downstream Stacks."
}

variable "vendor_chart_bundles" {
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
  description = "Immutable vendor OCI chart bundles and typed placement/network bindings consumed by the reusable public adapter."

  validation {
    condition = alltrue([
      for bundle in values(var.vendor_chart_bundles) :
      bundle.deployment_class == "testbed" &&
      !bundle.production_eligible &&
      can(regex("^testbed-[0-9]{8}-[1-9][0-9]*$", bundle.candidate_tag)) &&
      can(regex("^[0-9a-f]{40}$", bundle.product_commit)) &&
      can(regex("^[0-9a-f]{40}$", bundle.source_commit)) &&
      length(bundle.supported_agent_runtimes) > 0 &&
      length(bundle.image_digests) > 0 &&
      alltrue([for digest in values(bundle.image_digests) : can(regex("^sha256:[0-9a-f]{64}$", digest))]) &&
      alltrue([
        for chart in [bundle.charts.crds, bundle.charts.application] :
        can(regex("^oci://[^@]+@sha256:[0-9a-f]{64}$", chart.ref)) &&
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", chart.release_name)) &&
        can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", chart.version)) &&
        can(regex("^[0-9a-f]{64}$", chart.values_sha256)) &&
        sha256(base64decode(chart.values_base64)) == chart.values_sha256
      ]) &&
      alltrue([
        for namespace in values(bundle.namespaces) :
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", namespace.name)) &&
        contains(["testbed-control", "testbed-workload"], namespace.quota_profile)
      ]) &&
      alltrue([
        for endpoint in values(bundle.endpoints) :
        contains(keys(bundle.namespaces), endpoint.namespace_key) && length(endpoint.pod_selector) > 0
      ]) &&
      alltrue([
        for source in values(bundle.external_sources) :
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", source.namespace)) && length(source.pod_selector) > 0
      ]) &&
      alltrue([
        for flow in values(bundle.flows) :
        contains(["endpoint", "external"], flow.source_kind) &&
        (flow.source_kind == "endpoint" ? contains(keys(bundle.endpoints), flow.source_key) : contains(keys(bundle.external_sources), flow.source_key)) &&
        contains(keys(bundle.endpoints), flow.destination_key) &&
        length(flow.ports) > 0 &&
        alltrue([for port in flow.ports : port.port >= 1 && port.port <= 65535 && contains(["TCP", "UDP", "SCTP"], port.protocol)])
      ]) &&
      alltrue([for endpoint_key in bundle.kubernetes_api_egress_from : contains(keys(bundle.endpoints), endpoint_key)]) &&
      alltrue([
        for binding in values(bundle.database_bindings) :
        contains(keys(bundle.endpoints), binding.source_endpoint_key) &&
        binding.port >= 1 && binding.port <= 65535 &&
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", binding.secret_provider_class)) &&
        can(regex("^[A-Za-z0-9._-]+$", binding.secret_file))
      ])
    ])
    error_message = "Vendor bundles must be production-ineligible testbeds with exact product/chart/value/image pins and closed typed placement, flow, API and database bindings."
  }
}

variable "additional_database_users" {
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
  description = "Additional logical databases and roles for the existing protected Cloud SQL instance."

  validation {
    condition = alltrue([
      for user_name, settings in var.additional_database_users :
      can(regex("^[a-z_][a-z0-9_]*$", user_name)) &&
      !contains(["mattermost", "temporal", "yourown_chat_identity", "yourown_chat_identity_runtime"], user_name) &&
      length(settings.database_names) > 0 &&
      alltrue([for database_name in settings.database_names : can(regex("^[a-z_][a-z0-9_]*$", database_name))]) &&
      can(regex("^[A-Za-z0-9_-]+$", settings.password_secret_id)) &&
      (settings.connection_secret_id == null || (length(settings.database_names) == 1 && can(regex("^[A-Za-z0-9_-]+$", settings.connection_secret_id)))) &&
      alltrue([
        for accessor in settings.kubernetes_connection_secret_accessors :
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", accessor.namespace)) &&
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", accessor.service_account))
      ])
    ])
    error_message = "Additional database users require non-reserved PostgreSQL-safe names, Secret Manager IDs and DNS-safe Kubernetes service account accessors."
  }
}

variable "private_http_routes" {
  type = map(object({
    enabled   = bool
    namespace = string
    service   = string
    port      = number
  }))
  description = "Private hostname labels mapped to typed in-cluster HTTP Service origins for Cloudflare Access/Tunnel."

  validation {
    condition = alltrue([
      for label, route in var.private_http_routes :
      can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", label)) &&
      can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", route.namespace)) &&
      can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", route.service)) &&
      route.port >= 1 && route.port <= 65535
    ])
    error_message = "Private HTTP routes must use DNS-safe labels, namespaces and Services with valid ports."
  }
}
