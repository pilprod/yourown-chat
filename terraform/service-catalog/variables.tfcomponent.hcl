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

variable "kagent_testbed" {
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
  description = "Exact product-owned stock Kagent testbed lock consumed by the public typed vendor adapter."

  validation {
    condition = (
      !var.kagent_testbed.enabled ||
      (
        can(regex("^testbed-[0-9]{8}-[1-9][0-9]*$", var.kagent_testbed.candidate_tag)) &&
        can(regex("^[0-9a-f]{40}$", var.kagent_testbed.product_commit)) &&
        can(regex("^[0-9a-f]{40}$", var.kagent_testbed.source_commit)) &&
        can(regex("^sha256:[0-9a-f]{64}$", var.kagent_testbed.application_chart_oci_digest)) &&
        can(regex("^sha256:[0-9a-f]{64}$", var.kagent_testbed.crd_chart_oci_digest)) &&
        can(regex("^[0-9a-f]{64}$", var.kagent_testbed.application_values_sha256)) &&
        can(regex("^[0-9a-f]{64}$", var.kagent_testbed.crd_values_sha256)) &&
        var.kagent_testbed.namespace != var.kagent_testbed.workload_namespace &&
        startswith(var.kagent_testbed.ui_service, "http://")
      )
    )
    error_message = "Enabled kagent_testbed requires an immutable product/source lock, chart/value digests, distinct namespaces and an internal HTTP UI service."
  }
}

variable "private_upstreams" {
  type        = map(string)
  description = "Private hostname labels mapped to internal ClusterIP HTTP origins for the shared Cloudflare Access/Tunnel edge."

  validation {
    condition = alltrue([
      for label, service in var.private_upstreams :
      can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", label)) && startswith(service, "http://")
    ])
    error_message = "Private upstream labels must be lowercase DNS labels and services must be internal HTTP origins."
  }
}
