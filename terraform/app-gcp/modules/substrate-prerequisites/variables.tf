variable "bootstrap_enabled" {
  type        = bool
  description = "Create the namespace, immutable CRDs, RBAC and other non-workload prerequisites needed before native Secret synchronization."
  default     = false
}

variable "release_enabled" {
  type        = bool
  description = "Allow the separately managed Helm workload release only after bootstrap and native Secret synchronization are ready."
  default     = false

  validation {
    condition = !var.release_enabled || (
      var.bootstrap_enabled &&
      var.native_secret_sync_ready
    )
    error_message = "release_enabled requires bootstrap_enabled=true and native_secret_sync_ready=true."
  }
}

variable "gke_cluster_id" {
  type        = string
  description = "Fully-qualified GKE cluster ID used verbatim in the cluster-specific KSA issuer."

  validation {
    condition     = can(regex("^projects/[^/]+/locations/[^/]+/clusters/[^/]+$", var.gke_cluster_id))
    error_message = "gke_cluster_id must be a fully-qualified GKE cluster resource ID."
  }
}

variable "native_secret_sync_ready" {
  type        = bool
  description = "Explicit attestation that every Secret Manager value is populated and synchronized to its exact native Kubernetes Secret/key contract."
  default     = false
}

variable "local_provider_only" {
  type        = bool
  description = "Explicit testbed mode that admits only externally connected local providers and keeps Actor/MCP egress closed."
  default     = false

  validation {
    condition = !var.bootstrap_enabled || (
      (var.local_provider_only && length(var.atenet_egress_destinations) == 0) ||
      (!var.local_provider_only && length(var.atenet_egress_destinations) > 0)
    )
    error_message = "Enabled bootstrap requires either local_provider_only=true with no atenet destinations or local_provider_only=false with at least one reviewed destination."
  }
}

variable "kagent_control_planes" {
  type = map(object({
    namespace        = string
    release_name     = string
    agent_namespaces = map(string)
  }))
  description = "Exact dev/prod kagent controllers and their disjoint declarative per-agent namespaces."

  validation {
    condition = (
      toset(keys(var.kagent_control_planes)) == toset(["dev", "prod"]) &&
      try(var.kagent_control_planes.prod.namespace == "kagent-system", false) &&
      try(var.kagent_control_planes.prod.release_name == "kagent", false) &&
      try(var.kagent_control_planes.dev.namespace == "kagent-dev", false) &&
      try(var.kagent_control_planes.dev.release_name == "kagent-dev", false) &&
      alltrue(flatten([
        for control_key, control in var.kagent_control_planes : concat(
          [
            can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", control.namespace)),
            can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", control.release_name)),
            length(control.agent_namespaces) > 0,
          ],
          [
            for agent_id, namespace in control.agent_namespaces :
            can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", agent_id)) &&
            can(regex("^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$", namespace)) &&
            !contains(["ate-system", "kagent-system", "kagent-dev"], namespace)
          ],
        )
      ])) &&
      length(flatten([
        for control in values(var.kagent_control_planes) :
        concat([control.namespace], values(control.agent_namespaces))
        ])) == length(distinct(flatten([
          for control in values(var.kagent_control_planes) :
          concat([control.namespace], values(control.agent_namespaces))
      ])))
    )
    error_message = "kagent_control_planes must define exact dev/prod controllers with unique DNS-safe, non-overlapping per-agent namespaces."
  }
}

variable "secret_contract" {
  type = map(object({
    secret_manager_id = string
    namespace         = string
    kubernetes_name   = string
    keys              = set(string)
  }))
  description = "Non-secret identifiers for the external-control-plane native Kubernetes Secret contract."
  default     = {}
}

variable "derived_secret_contract" {
  type = map(object({
    source_secret_key = string
    namespace         = string
    kubernetes_name   = string
    keys              = set(string)
  }))
  description = "Non-secret contract for Kubernetes-only values derived from one of the eight Secret Manager-backed sources."
  default     = {}
}

variable "cloudsql_private_ip" {
  type        = string
  description = "Exact private Cloud SQL address allowed from ate-api-server on TCP/5432."

  validation {
    condition     = can(cidrhost("${var.cloudsql_private_ip}/32", 0))
    error_message = "cloudsql_private_ip must be an IPv4 address."
  }
}

variable "cluster_dns_ip" {
  type        = string
  description = "Exact kube-dns Service ClusterIP allowed by the Substrate control-plane NetworkPolicies."

  validation {
    condition     = can(cidrhost("${var.cluster_dns_ip}/32", 0))
    error_message = "cluster_dns_ip must be an IPv4 address."
  }
}

variable "substrate_crd_chart" {
  type = object({
    ref     = string
    version = string
  })
  description = "Immutable Substrate fork CRD chart owned by Terraform, never Cloud Deploy."
  default = {
    ref     = ""
    version = ""
  }

  validation {
    condition = !var.bootstrap_enabled || (
      can(regex("^oci://[^@]+@sha256:[0-9a-f]{64}$", var.substrate_crd_chart.ref)) &&
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+", var.substrate_crd_chart.version))
    )
    error_message = "Enabled Substrate prerequisites require a digest-qualified OCI CRD chart and explicit semantic version."
  }
}

variable "atenet_egress_destinations" {
  type = map(object({
    cidr = string
    port = number
  }))
  description = "Reviewed Actor/MCP destination CIDRs and TCP ports allowed from atenet-egress. Empty keeps delivery fail-closed."
  default     = {}

  validation {
    condition = alltrue([
      for destination in values(var.atenet_egress_destinations) :
      can(cidrhost(destination.cidr, 0)) &&
      destination.cidr != "0.0.0.0/0" &&
      destination.cidr != "::/0" &&
      destination.port >= 1 &&
      destination.port <= 65535
    ])
    error_message = "atenet egress destinations must use explicit non-default CIDRs and valid TCP ports."
  }
}

variable "agentgateway" {
  type = object({
    namespace                  = string
    service_account_name       = string
    deployer_cluster_role_name = string
  })
  description = "Platform-owned agentgateway identity and deployer role bound only in the app Gateway namespace."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to Terraform-owned prerequisites."
  default     = {}
}
