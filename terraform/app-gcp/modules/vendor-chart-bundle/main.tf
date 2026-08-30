locals {
  provisioned = var.bundle.provisioned

  namespaces = {
    for namespace_key, namespace in var.bundle.namespaces : namespace_key => namespace
    if local.provisioned
  }

  control_namespace = one([
    for namespace in values(var.bundle.namespaces) : namespace.name
    if namespace.quota_profile == "testbed-control"
  ])

  endpoint_details = {
    for endpoint_key, endpoint in var.bundle.endpoints : endpoint_key => {
      namespace    = var.bundle.namespaces[endpoint.namespace_key].name
      pod_selector = endpoint.pod_selector
    }
  }

  flows = {
    for flow_key, flow in var.bundle.flows : flow_key => {
      source_namespace      = flow.source_kind == "endpoint" ? local.endpoint_details[flow.source_key].namespace : var.bundle.external_sources[flow.source_key].namespace
      source_selector       = flow.source_kind == "endpoint" ? local.endpoint_details[flow.source_key].pod_selector : var.bundle.external_sources[flow.source_key].pod_selector
      destination_namespace = local.endpoint_details[flow.destination_key].namespace
      destination_selector  = local.endpoint_details[flow.destination_key].pod_selector
      ports                 = flow.ports
    }
    if local.provisioned
  }

  # The hash suffix keeps names unique when several bundles write additive
  # policies into the same external source namespace while staying under the
  # Kubernetes 63-character object-name limit.
  flow_policy_stems = {
    for flow_key in keys(var.bundle.flows) :
    flow_key => "${substr(replace("${var.bundle_key}-${flow_key}", "_", "-"), 0, 32)}-${substr(sha256("${var.bundle_key}/${flow_key}"), 0, 8)}"
  }

  api_policy_stems = {
    for endpoint_key in var.bundle.kubernetes_api_egress_from :
    endpoint_key => "${substr(replace("${var.bundle_key}-${endpoint_key}", "_", "-"), 0, 32)}-${substr(sha256("${var.bundle_key}/${endpoint_key}"), 0, 8)}"
  }

  database_policy_stems = {
    for binding_key in keys(var.bundle.database_bindings) :
    binding_key => "${substr(replace("${var.bundle_key}-${binding_key}", "_", "-"), 0, 32)}-${substr(sha256("${var.bundle_key}/${binding_key}"), 0, 8)}"
  }

  database_bindings_ready = alltrue([
    for binding in values(var.bundle.database_bindings) :
    trimspace(lookup(var.database_secret_ids, binding.secret_id_key, "")) != ""
  ])

  ready_database_bindings = {
    for binding_key, binding in var.bundle.database_bindings : binding_key => binding
    if local.provisioned && trimspace(lookup(var.database_secret_ids, binding.secret_id_key, "")) != ""
  }

  application_ready = local.provisioned && var.bundle.application_enabled && local.database_bindings_ready

  # The Stack runs this component from terraform/app-gcp/modules. Resolve only
  # the validated helm/vendor/<bundle>/*.values.yaml paths from the checked-out
  # repository; no opaque values payload travels through deployment inputs.
  repository_root         = abspath("${path.module}/../../../..")
  crd_values_path         = "${local.repository_root}/${var.bundle.charts.crds.values_path}"
  application_values_path = "${local.repository_root}/${var.bundle.charts.application.values_path}"
  crd_values              = try(file(local.crd_values_path), "")
  application_values      = try(file(local.application_values_path), "")

  quota_profiles = {
    testbed-control = {
      pods                   = "10"
      persistentvolumeclaims = "0"
      "requests.cpu"         = "2"
      "requests.memory"      = "4Gi"
      "requests.storage"     = "0"
      "limits.cpu"           = "8"
      "limits.memory"        = "8Gi"
    }
    testbed-workload = {
      pods                   = "20"
      persistentvolumeclaims = "0"
      "requests.cpu"         = "4"
      "requests.memory"      = "8Gi"
      "requests.storage"     = "0"
      "limits.cpu"           = "12"
      "limits.memory"        = "16Gi"
    }
  }
}

resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.value.name
    labels = merge(var.labels, {
      "platform.yourown.chat/vendor-bundle"        = var.bundle_key
      "platform.yourown.chat/deployment-class"     = var.bundle.deployment_class
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  for_each = local.namespaces

  metadata {
    name      = "vendor-compute-budget"
    namespace = each.value.name
  }

  spec {
    hard = local.quota_profiles[each.value.quota_profile]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_limit_range_v1" "this" {
  for_each = local.namespaces

  metadata {
    name      = "vendor-container-defaults"
    namespace = each.value.name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "1"
        memory = "1Gi"
      }
      default_request = {
        cpu    = "25m"
        memory = "64Mi"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# Every managed namespace is closed in both directions. The policies below add
# only bundle-declared paths; no same-namespace or cluster-wide exception is
# implicit in this module.
resource "kubernetes_network_policy_v1" "default_deny" {
  for_each = local.namespaces

  metadata {
    name      = "default-deny-ingress-egress"
    namespace = each.value.name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# DNS is the only namespace-wide egress allowance and targets the exact cluster
# DNS Service address and the managed DNS pods on TCP/UDP 53.
resource "kubernetes_network_policy_v1" "dns_egress" {
  for_each = local.namespaces

  metadata {
    name      = "allow-cluster-dns-egress"
    namespace = each.value.name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "${var.cluster_dns_ip}/32"
        }
      }

      # GKE Dataplane V2 does not apply ipBlock destinations to Pod IPs. Select
      # both supported GKE DNS implementations by namespace and pod identity.
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        pod_selector {
          match_expressions {
            key      = "k8s-app"
            operator = "In"
            values   = ["kube-dns", "node-local-dns"]
          }
        }
      }

      ports {
        port     = "53"
        protocol = "TCP"
      }

      ports {
        port     = "53"
        protocol = "UDP"
      }
    }
  }

  depends_on = [kubernetes_network_policy_v1.default_deny]
}

# Every declared application path is rendered as a paired destination ingress
# rule and source egress rule. A declaration can never open only one side.
resource "kubernetes_network_policy_v1" "flow_ingress" {
  for_each = local.flows

  metadata {
    name      = "allow-${local.flow_policy_stems[each.key]}-ingress"
    namespace = each.value.destination_namespace
  }

  spec {
    pod_selector {
      match_labels = each.value.destination_selector
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = each.value.source_namespace
          }
        }
        pod_selector {
          match_labels = each.value.source_selector
        }
      }

      dynamic "ports" {
        for_each = each.value.ports
        content {
          port     = tostring(ports.value.port)
          protocol = ports.value.protocol
        }
      }
    }
  }

  depends_on = [kubernetes_network_policy_v1.default_deny]
}

resource "kubernetes_network_policy_v1" "flow_egress" {
  for_each = local.flows

  metadata {
    name      = "allow-${local.flow_policy_stems[each.key]}-egress"
    namespace = each.value.source_namespace
  }

  spec {
    pod_selector {
      match_labels = each.value.source_selector
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = each.value.destination_namespace
          }
        }
        pod_selector {
          match_labels = each.value.destination_selector
        }
      }

      dynamic "ports" {
        for_each = each.value.ports
        content {
          port     = tostring(ports.value.port)
          protocol = ports.value.protocol
        }
      }
    }
  }

  depends_on = [kubernetes_network_policy_v1.default_deny]
}

data "kubernetes_service_v1" "api" {
  count = local.provisioned && length(var.bundle.kubernetes_api_egress_from) > 0 ? 1 : 0

  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

data "kubernetes_endpoints_v1" "api" {
  count = local.provisioned && length(var.bundle.kubernetes_api_egress_from) > 0 ? 1 : 0

  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

locals {
  kubernetes_api_service_ip = try(data.kubernetes_service_v1.api[0].spec[0].cluster_ip, null)
  kubernetes_api_https_subsets = [
    for subset in try(data.kubernetes_endpoints_v1.api[0].subset, []) : subset
    if anytrue([
      for port in subset.port : port.port == 443 && port.protocol == "TCP"
    ])
  ]
  kubernetes_api_endpoint_ips = toset(flatten([
    for subset in local.kubernetes_api_https_subsets : [
      for address in subset.address : address.ip
    ]
  ]))
  kubernetes_api_destination_ips = setunion(
    local.kubernetes_api_service_ip == null ? toset([]) : toset([local.kubernetes_api_service_ip]),
    local.kubernetes_api_endpoint_ips,
  )
}

resource "kubernetes_network_policy_v1" "kubernetes_api_egress" {
  for_each = local.provisioned ? var.bundle.kubernetes_api_egress_from : toset([])

  metadata {
    name      = "allow-${local.api_policy_stems[each.key]}-api-egress"
    namespace = local.endpoint_details[each.key].namespace
  }

  spec {
    pod_selector {
      match_labels = local.endpoint_details[each.key].pod_selector
    }
    policy_types = ["Egress"]

    egress {
      # NetworkPolicy enforcement can observe a Service connection either
      # before or after destination NAT. Permit the exact ClusterIP and the
      # exact ready TCP/443 endpoint addresses, never a control-plane CIDR.
      dynamic "to" {
        for_each = local.kubernetes_api_destination_ips
        iterator = api_destination

        content {
          ip_block {
            cidr = "${api_destination.value}/32"
          }
        }
      }

      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.kubernetes_api_endpoint_ips) > 0
      error_message = "The kubernetes Service must publish at least one ready TCP/443 endpoint before API egress can be opened."
    }
  }

  depends_on = [kubernetes_network_policy_v1.default_deny]
}

resource "kubernetes_network_policy_v1" "database_egress" {
  for_each = local.provisioned ? var.bundle.database_bindings : {}

  metadata {
    name      = "allow-${local.database_policy_stems[each.key]}-database-egress"
    namespace = local.endpoint_details[each.value.source_endpoint_key].namespace
  }

  spec {
    pod_selector {
      match_labels = local.endpoint_details[each.value.source_endpoint_key].pod_selector
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "${var.cloudsql_private_ip}/32"
        }
      }
      ports {
        port     = tostring(each.value.port)
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_network_policy_v1.default_deny]
}

# The GKE Secret Manager CSI driver resolves the URI only for the bundle-bound
# endpoint service account. Secret bytes never pass through Terraform state.
resource "kubernetes_manifest" "database_secret_provider_class" {
  for_each = local.ready_database_bindings

  manifest = {
    apiVersion = "secrets-store.csi.x-k8s.io/v1"
    kind       = "SecretProviderClass"
    metadata = {
      name      = each.value.secret_provider_class
      namespace = local.endpoint_details[each.value.source_endpoint_key].namespace
      labels = merge(var.labels, {
        "platform.yourown.chat/vendor-bundle" = var.bundle_key
      })
    }
    spec = {
      provider = "gke"
      parameters = {
        secrets = yamlencode([{
          resourceName = "projects/${var.project_id}/secrets/${var.database_secret_ids[each.value.secret_id_key]}/versions/latest"
          path         = each.value.secret_file
        }])
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# Cluster-scoped definitions are a separately pinned release. Destruction is
# intentionally blocked because other releases may already use these APIs.
resource "helm_release" "crds" {
  count = local.provisioned ? 1 : 0

  name      = var.bundle.charts.crds.release_name
  chart     = var.bundle.charts.crds.ref
  version   = var.bundle.charts.crds.version
  namespace = local.control_namespace

  create_namespace = false
  values           = [local.crd_values]

  atomic            = false
  cleanup_on_fail   = false
  dependency_update = false
  lint              = true
  max_history       = 5
  pass_credentials  = false
  replace           = false
  reset_values      = true
  reuse_values      = false
  timeout           = 900
  wait              = true
  wait_for_jobs     = true

  description = "${var.bundle.candidate_tag}; source=${var.bundle.source_commit}; values=sha256:${var.bundle.charts.crds.values_sha256}"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = fileexists(local.crd_values_path) && sha256(local.crd_values) == var.bundle.charts.crds.values_sha256
      error_message = "The tracked CRD values file is missing or does not match the declared bundle checksum."
    }

    precondition {
      condition     = try(length(keys(yamldecode(local.crd_values))) >= 0, false)
      error_message = "The tracked CRD values file must contain a YAML object."
    }
  }

  depends_on = [
    kubernetes_limit_range_v1.this,
    kubernetes_network_policy_v1.default_deny,
    kubernetes_resource_quota_v1.this,
  ]
}

# Phase A of the ownership handoff. Apply this address-only move before a later
# configuration forgets the handoff source with destroy=false.
moved {
  from = helm_release.application
  to   = helm_release.application_handoff_source
}

resource "helm_release" "application_handoff_source" {
  count = local.application_ready ? 1 : 0

  name      = var.bundle.charts.application.release_name
  chart     = var.bundle.charts.application.ref
  version   = var.bundle.charts.application.version
  namespace = local.control_namespace

  create_namespace = false
  values           = [local.application_values]

  atomic            = true
  cleanup_on_fail   = true
  dependency_update = false
  lint              = true
  max_history       = 5
  pass_credentials  = false
  reset_values      = true
  skip_crds         = true
  timeout           = 900
  wait              = true
  wait_for_jobs     = true

  description = "${var.bundle.candidate_tag}; product=${var.bundle.product_commit}; source=${var.bundle.source_commit}; values=sha256:${var.bundle.charts.application.values_sha256}"

  lifecycle {
    precondition {
      condition     = fileexists(local.application_values_path) && sha256(local.application_values) == var.bundle.charts.application.values_sha256
      error_message = "The tracked application values file is missing or does not match the declared bundle checksum."
    }

    precondition {
      condition     = try(length(keys(yamldecode(local.application_values))) >= 0, false)
      error_message = "The tracked application values file must contain a YAML object."
    }

    precondition {
      condition = alltrue([
        for digest in values(var.bundle.image_digests) :
        strcontains(local.application_values, digest)
      ])
      error_message = "Every declared image digest must be present in the tracked application values file."
    }
  }

  depends_on = [
    helm_release.crds,
    kubernetes_manifest.database_secret_provider_class,
    kubernetes_network_policy_v1.database_egress,
    kubernetes_network_policy_v1.dns_egress,
    kubernetes_network_policy_v1.flow_egress,
    kubernetes_network_policy_v1.flow_ingress,
    kubernetes_network_policy_v1.kubernetes_api_egress,
  ]
}
