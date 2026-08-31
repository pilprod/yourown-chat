variable "bootstrap_enabled" {
  type        = bool
  description = "Create the namespace, immutable CRDs, RBAC and other non-workload prerequisites needed before native Secret synchronization."
  default     = false
}

variable "adopt_existing" {
  type        = bool
  description = "One-shot import of the exact existing ate-system namespace, authentication ConfigMap, Substrate RBAC and substrate/substrate-crds Helm releases; clear after the staged bootstrap/application handoff is complete."
  default     = false

  validation {
    condition     = !var.adopt_existing || var.bootstrap_enabled
    error_message = "adopt_existing requires bootstrap_enabled=true so the namespace and CRD release have Terraform addresses."
  }
}

variable "adopt_existing_substrate_compatibility_confirmed" {
  type        = bool
  description = "Explicit reviewed attestation that both existing Substrate Helm releases can be adopted and upgraded to the pinned charts. Required for an existing-cluster bootstrap handoff because the CRD release is imported and reconciled in that stage."
  default     = false

  validation {
    condition = !(
      var.adopt_existing &&
      var.bootstrap_enabled
    ) || var.adopt_existing_substrate_compatibility_confirmed
    error_message = "adopt_existing with bootstrap_enabled requires adopt_existing_substrate_compatibility_confirmed=true after both live-to-pinned Helm release plans have been reviewed."
  }
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

variable "external_broker_smoke_ready" {
  type        = bool
  description = "Reviewed live attestation consumed by the Cloud Deploy production predeploy gate. False must still allow the dev rollout."
  default     = false
}

variable "external_broker_smoke_release" {
  type        = string
  description = "Exact Cloud Deploy release ID whose immutable dev candidate passed the external Agent Host TLS+gRPC smoke."
  default     = ""

  validation {
    condition = var.external_broker_smoke_ready ? (
      var.release_enabled &&
      can(regex(
        "^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
        var.external_broker_smoke_release,
      ))
      ) : (
      var.external_broker_smoke_release == ""
    )
    error_message = "A true external Broker smoke attestation requires release_enabled=true and its exact Cloud Deploy release ID; false requires an empty release ID."
  }
}

variable "promotion_gate_reader_email" {
  type        = string
  description = "Dedicated Cloud Deploy PREDEPLOY Google service account admitted to read only the production promotion ConfigMap."
  default     = ""

  validation {
    condition = !var.bootstrap_enabled || can(regex(
      "^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\\.iam\\.gserviceaccount\\.com$",
      var.promotion_gate_reader_email,
    ))
    error_message = "Enabled Substrate bootstrap requires the exact Cloud Deploy PREDEPLOY service account email for the promotion gate."
  }
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

variable "substrate_application_chart" {
  type = object({
    ref     = string
    version = string
  })
  description = "Immutable Substrate application chart owned by app-gcp and never by kagent Cloud Deploy promotion."
  default = {
    ref     = ""
    version = ""
  }

  validation {
    condition = !var.release_enabled || (
      can(regex("^oci://[^@]+@sha256:[0-9a-f]{64}$", var.substrate_application_chart.ref)) &&
      can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+", var.substrate_application_chart.version))
    )
    error_message = "Enabled Substrate release requires a digest-qualified OCI application chart and explicit semantic version."
  }
}

variable "substrate_helm_set_values" {
  type        = map(string)
  description = "Exact immutable image-only overrides admitted from the reviewed Substrate release receipt."
  default     = {}
}

variable "substrate_values_sha256" {
  type        = string
  description = "Reviewed SHA-256 of helm/kagent/substrate.values.yaml."
  default     = ""

  validation {
    condition     = !var.release_enabled || can(regex("^[0-9a-f]{64}$", var.substrate_values_sha256))
    error_message = "Enabled Substrate release requires the tracked application values SHA-256."
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
    public_ip_name             = string
  })
  description = "Platform-owned agentgateway identity, deployer role and dedicated address bound only to the app Gateway namespace."
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to Terraform-owned prerequisites."
  default     = {}
}
