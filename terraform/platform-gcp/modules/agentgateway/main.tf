locals {
  gateway_api_version          = "v1.6.0"
  gateway_api_asset            = "${path.module}/files/gateway-api-v1.6.0-standard-install.yaml"
  gateway_api_asset_sha256     = "a557172e8348f758479e9ee4000bbbb4b4aa48302a6b73461823ea5349bad56d"
  agentgateway_chart           = "oci://cr.agentgateway.dev/charts/agentgateway@sha256:9216ce83965ad2ce0888014d14aac5e71333fd9d4057cd167da92b37630fbee1"
  agentgateway_crds_chart      = "oci://cr.agentgateway.dev/charts/agentgateway-crds@sha256:3a6cf44559c612ac8afb7f867aace69bbd4cdba765f1def6377b7a3186c603e3"
  agentgateway_chart_version   = "v1.5.0"
  agentgateway_controller_tag  = "v1.5.0@sha256:319489cb86b7f901a52a3fc532ad07f136c92756f88cf02a4040909e20001120"
  agentgateway_proxy_tag       = "v1.5.0@sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896"
  agentgateway_controller      = "agentgateway.dev/agentgateway"
  agentgateway_gateway_class   = "agentgateway"
  agentgateway_service_account = "agentgateway"

  # Documented v1.5.0 chart names for release `agentgateway`. The chart owns
  # these roles; Terraform owns the ServiceAccount and bindings so platform
  # installation never writes RoleBindings into app-owned namespaces.
  read_cluster_role_name     = "agentgateway-${var.namespace}"
  deployer_cluster_role_name = "agentgateway-${var.namespace}-deployer"
  local_role_name            = "agentgateway-${var.namespace}-local"

  # Upstream publishes Gateway API as a multi-document release asset, not as
  # an official Helm chart. Decode the exact vendored standard-channel asset
  # so Terraform owns every CRD and its safe-upgrade admission policy without
  # downloading executable configuration during apply.
  gateway_api_documents = [
    for document in split("\n---\n", trimspace(file(local.gateway_api_asset))) :
    yamldecode(document)
    if can(regex("(?m)^apiVersion:", document))
  ]
  gateway_api_manifests = {
    for manifest in local.gateway_api_documents :
    "${manifest.kind}/${manifest.metadata.name}" => manifest
  }

  namespace_labels = merge(var.labels, {
    "app.kubernetes.io/name"             = "agentgateway"
    "app.kubernetes.io/part-of"          = "yourown-chat-platform"
    "app.kubernetes.io/managed-by"       = "terraform"
    "platform.yourown.chat/tier"         = "gateway-control-plane"
    "pod-security.kubernetes.io/enforce" = "restricted"
    "pod-security.kubernetes.io/audit"   = "restricted"
    "pod-security.kubernetes.io/warn"    = "restricted"
  })

  # The chart authors app.kubernetes.io/name and managed-by itself. Passing the
  # namespace labels as commonLabels would render duplicate YAML keys.
  chart_common_labels = {
    "platform.yourown.chat/owner" = "platform-gcp"
    "platform.yourown.chat/tier"  = "gateway-control-plane"
  }
}

resource "kubernetes_namespace_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name   = var.namespace
    labels = local.namespace_labels
  }
}

resource "kubernetes_service_account_v1" "controller" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = local.agentgateway_service_account
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.chart_common_labels
  }
}

resource "kubernetes_manifest" "gateway_api_standard" {
  for_each = {
    for key, manifest in local.gateway_api_manifests : key => manifest
    if var.enabled
  }

  manifest = each.value

  field_manager {
    force_conflicts = true
    name            = "terraform-platform-gcp"
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = filesha256(local.gateway_api_asset) == local.gateway_api_asset_sha256
      error_message = "The vendored Gateway API v1.6.0 standard-channel asset does not match its reviewed upstream SHA-256."
    }
  }
}

# The project-specific CRDs are cluster-scoped and deliberately owned by the
# platform stack. Application pipelines must never install this chart.
resource "helm_release" "crds" {
  count = var.enabled ? 1 : 0

  name             = "agentgateway-crds"
  chart            = local.agentgateway_crds_chart
  version          = local.agentgateway_chart_version
  namespace        = kubernetes_namespace_v1.this[0].metadata[0].name
  create_namespace = false

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

  description = "Official agentgateway CRDs ${local.agentgateway_chart_version}; Terraform platform owner"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [kubernetes_manifest.gateway_api_standard]
}

resource "helm_release" "controller" {
  count = var.enabled ? 1 : 0

  name             = "agentgateway"
  chart            = local.agentgateway_chart
  version          = local.agentgateway_chart_version
  namespace        = kubernetes_namespace_v1.this[0].metadata[0].name
  create_namespace = false

  values = [yamlencode({
    commonLabels = local.chart_common_labels
    image = {
      pullPolicy = "IfNotPresent"
      registry   = "cr.agentgateway.dev"
      tag        = local.agentgateway_proxy_tag
    }
    controller = {
      logLevel = "info"
      image = {
        pullPolicy = "IfNotPresent"
        registry   = "cr.agentgateway.dev"
        repository = "controller"
        tag        = local.agentgateway_controller_tag
      }
      replicaCount = 1
    }
    proxy = {
      image = {
        registry   = "cr.agentgateway.dev"
        repository = "agentgateway"
        tag        = local.agentgateway_proxy_tag
      }
    }
    agentgatewayModels = { enabled = false }
    inferenceExtension = { enabled = false }
    serviceAccount = {
      create = false
      name   = local.agentgateway_service_account
    }
    rbac = {
      # A non-empty platform namespace suppresses the default cluster-wide
      # write binding. app-gcp binds the generated deployer ClusterRole in its
      # namespace after that namespace exists.
      gatewayNamespaces = [var.namespace]
    }
    discoveryNamespaceSelectors = [
      {
        matchLabels = {
          "kubernetes.io/metadata.name" = var.namespace
        }
      },
      {
        matchLabels = {
          "gateway-controller" = "agentgateway"
        }
      },
    ]
    podSecurityContext = {
      runAsNonRoot = true
      seccompProfile = {
        type = "RuntimeDefault"
      }
    }
    securityContext = {
      allowPrivilegeEscalation = false
      capabilities             = { drop = ["ALL"] }
      readOnlyRootFilesystem   = true
      runAsNonRoot             = true
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
  })]

  atomic            = true
  cleanup_on_fail   = true
  dependency_update = false
  lint              = true
  max_history       = 5
  pass_credentials  = false
  replace           = false
  reset_values      = true
  reuse_values      = false
  skip_crds         = true
  timeout           = 900
  wait              = true
  wait_for_jobs     = true

  description = "Official agentgateway Kubernetes control plane ${local.agentgateway_chart_version}"

  depends_on = [
    helm_release.crds,
    kubernetes_service_account_v1.controller,
    kubernetes_cluster_role_binding_v1.controller_read,
    kubernetes_role_binding_v1.controller_local,
  ]
}

# serviceAccount.create=false disables all chart-created bindings. Restore only
# the read and controller-namespace bindings here; no cluster-wide write
# ClusterRoleBinding is ever created.
resource "kubernetes_cluster_role_binding_v1" "controller_read" {
  count = var.enabled ? 1 : 0

  metadata {
    name   = "agentgateway-read-${var.namespace}"
    labels = local.chart_common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = local.read_cluster_role_name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.agentgateway_service_account
    namespace = var.namespace
  }

  depends_on = [kubernetes_service_account_v1.controller]
}

resource "kubernetes_role_binding_v1" "controller_local" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "agentgateway-local"
    namespace = var.namespace
    labels    = local.chart_common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = local.local_role_name
  }

  subject {
    kind      = "ServiceAccount"
    name      = local.agentgateway_service_account
    namespace = var.namespace
  }

  depends_on = [kubernetes_service_account_v1.controller]
}
