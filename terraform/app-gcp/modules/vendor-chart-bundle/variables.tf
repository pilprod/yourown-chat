variable "bundle_key" {
  type        = string
  description = "Stable catalog key used only for generic ownership labels and output correlation."

  validation {
    condition     = can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", var.bundle_key)) && length(var.bundle_key) <= 63
    error_message = "bundle_key must be a DNS-safe label value."
  }
}

variable "bundle" {
  type = object({
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
  })
  description = "Closed private-catalog contract for one immutable, production-ineligible vendor chart bundle."

  validation {
    condition = (
      (!var.bundle.application_enabled || var.bundle.provisioned) &&
      var.bundle.deployment_class == "testbed" &&
      !var.bundle.production_eligible &&
      can(regex("^testbed-[0-9]{8}-[1-9][0-9]*$", var.bundle.candidate_tag)) &&
      can(regex("^[0-9a-f]{40}$", var.bundle.product_commit)) &&
      can(regex("^[0-9a-f]{40}$", var.bundle.source_commit)) &&
      length(var.bundle.supported_agent_runtimes) > 0 &&
      length(var.bundle.image_digests) > 0 &&
      alltrue([for digest in values(var.bundle.image_digests) : can(regex("^sha256:[0-9a-f]{64}$", digest))]) &&
      try(alltrue([
        for digest in values(var.bundle.image_digests) :
        strcontains(base64decode(var.bundle.charts.application.values_base64), digest)
      ]), false) &&
      alltrue([
        for chart in [var.bundle.charts.crds, var.bundle.charts.application] :
        can(regex("^oci://[^@]+@sha256:[0-9a-f]{64}$", chart.ref)) &&
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", chart.release_name)) &&
        can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", chart.version)) &&
        can(regex("^[0-9a-f]{64}$", chart.values_sha256)) &&
        can(base64decode(chart.values_base64)) &&
        try(sha256(base64decode(chart.values_base64)) == chart.values_sha256, false)
      ]) &&
      length([for namespace in values(var.bundle.namespaces) : namespace if namespace.quota_profile == "testbed-control"]) == 1 &&
      alltrue([
        for namespace in values(var.bundle.namespaces) :
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", namespace.name)) &&
        contains(["testbed-control", "testbed-workload"], namespace.quota_profile)
      ]) &&
      alltrue([
        for endpoint_key, endpoint in var.bundle.endpoints :
        can(regex("^[a-z0-9](?:[-_a-z0-9]*[a-z0-9])?$", endpoint_key)) &&
        contains(keys(var.bundle.namespaces), endpoint.namespace_key) && length(endpoint.pod_selector) > 0
      ]) &&
      alltrue([
        for source_key, source in var.bundle.external_sources :
        can(regex("^[a-z0-9](?:[-_a-z0-9]*[a-z0-9])?$", source_key)) &&
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", source.namespace)) && length(source.pod_selector) > 0
      ]) &&
      alltrue([
        for flow_key, flow in var.bundle.flows :
        can(regex("^[a-z0-9](?:[-_a-z0-9]*[a-z0-9])?$", flow_key)) &&
        length(flow_key) <= 40 &&
        contains(["endpoint", "external"], flow.source_kind) &&
        (flow.source_kind == "endpoint" ? contains(keys(var.bundle.endpoints), flow.source_key) : contains(keys(var.bundle.external_sources), flow.source_key)) &&
        contains(keys(var.bundle.endpoints), flow.destination_key) &&
        length(flow.ports) > 0 &&
        alltrue([for port in flow.ports : port.port >= 1 && port.port <= 65535 && contains(["TCP", "UDP", "SCTP"], port.protocol)])
      ]) &&
      length(distinct([for flow_key in keys(var.bundle.flows) : replace(flow_key, "_", "-")])) == length(var.bundle.flows) &&
      alltrue([for endpoint_key in var.bundle.kubernetes_api_egress_from : contains(keys(var.bundle.endpoints), endpoint_key)]) &&
      alltrue([
        for binding_key, binding in var.bundle.database_bindings :
        can(regex("^[a-z0-9](?:[-_a-z0-9]*[a-z0-9])?$", binding_key)) &&
        length(binding_key) <= 40 &&
        contains(keys(var.bundle.endpoints), binding.source_endpoint_key) &&
        binding.port >= 1 && binding.port <= 65535 &&
        can(regex("^[A-Za-z0-9_-]+$", binding.secret_id_key)) &&
        can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", binding.secret_provider_class)) &&
        can(regex("^[A-Za-z0-9._-]+$", binding.secret_file))
      ])
    )
    error_message = "The bundle must be a closed immutable testbed contract with exact chart/value/image pins and valid typed placement, flow, API and database bindings."
  }
}

variable "project_id" {
  type        = string
  description = "Google Cloud project containing Secret Manager database connection secrets."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "cluster_dns_ip" {
  type        = string
  description = "Exact cluster DNS service IPv4 address used by the deny-by-default egress policy."

  validation {
    condition     = !var.bundle.provisioned || can(cidrhost("${var.cluster_dns_ip}/32", 0))
    error_message = "A provisioned bundle requires a valid cluster DNS IPv4 address."
  }
}

variable "cloudsql_private_ip" {
  type        = string
  description = "Exact private database IPv4 address used only by typed database bindings."
  default     = ""

  validation {
    condition     = !var.bundle.provisioned || length(var.bundle.database_bindings) == 0 || can(cidrhost("${var.cloudsql_private_ip}/32", 0))
    error_message = "A provisioned database binding requires a valid private database IPv4 address."
  }
}

variable "database_secret_ids" {
  type        = map(string)
  description = "Platform-published logical database key to ready Secret Manager connection-secret ID. Missing entries keep the application release closed."
  default     = {}

  validation {
    condition     = alltrue([for secret_id in values(var.database_secret_ids) : can(regex("^[A-Za-z0-9_-]+$", secret_id))])
    error_message = "Database secret IDs must be valid Secret Manager IDs."
  }
}

variable "labels" {
  type        = map(string)
  description = "Non-sensitive platform ownership labels applied to Terraform-owned Kubernetes resources."
  default     = {}
}
