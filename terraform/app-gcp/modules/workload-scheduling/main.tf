resource "kubernetes_priority_class_v1" "production" {
  metadata {
    name = "production"
  }

  value             = 100000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Production workloads may preempt disposable development workloads."
}

resource "kubernetes_priority_class_v1" "platform_default" {
  metadata {
    name = "platform-default"
  }

  # Operator-generated Mattermost pods/jobs cannot set priorityClassName
  # directly. Making the safe platform baseline the global default keeps them
  # above explicitly disposable dev workloads without experimental CR patches.
  value             = 10000
  global_default    = true
  preemption_policy = "PreemptLowerPriority"
  description       = "Default priority for platform, operator and system-adjacent workloads."
}

resource "kubernetes_priority_class_v1" "development" {
  metadata {
    name = "development"
  }

  # Below Kubernetes' implicit default priority (0), so operator jobs and
  # system workloads remain ahead of disposable dev instances.
  value             = -1000
  global_default    = false
  preemption_policy = "PreemptLowerPriority"
  description       = "Disposable development and migration-test workloads."
}

resource "kubernetes_resource_quota_v1" "dev" {
  metadata {
    name      = "compute-budget"
    namespace = var.dev_namespace
  }

  spec {
    hard = {
      "pods"            = "30"
      "requests.cpu"    = "1"
      "requests.memory" = "2Gi"
      "limits.cpu"      = "4"
      "limits.memory"   = "4Gi"
    }
  }
}

resource "kubernetes_limit_range_v1" "dev" {
  metadata {
    name      = "container-defaults"
    namespace = var.dev_namespace
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "10m"
        memory = "32Mi"
      }
    }
  }
}

resource "kubernetes_resource_quota_v1" "agent_pilot" {
  count = var.agent_enabled ? 1 : 0

  metadata {
    name      = "compute-budget"
    namespace = var.agent_namespace
  }

  spec {
    hard = {
      "pods"            = "15"
      "requests.cpu"    = "1"
      "requests.memory" = "2Gi"
      "limits.cpu"      = "4"
      "limits.memory"   = "4Gi"
    }
  }
}

resource "kubernetes_limit_range_v1" "agent_pilot" {
  count = var.agent_enabled ? 1 : 0

  metadata {
    name      = "container-defaults"
    namespace = var.agent_namespace
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "10m"
        memory = "32Mi"
      }
    }
  }
}

locals {
  kagent_namespaces_enabled = var.kagent_preview_enabled || var.kagent_testbed_enabled
}

resource "kubernetes_resource_quota_v1" "kagent_testbed" {
  for_each = local.kagent_namespaces_enabled ? toset([
    var.kagent_system_namespace,
    var.kagent_testbed_namespace,
  ]) : toset([])

  metadata {
    name      = "compute-budget"
    namespace = each.value
  }

  spec {
    hard = {
      "pods"            = each.value == var.kagent_system_namespace ? "10" : "20"
      "requests.cpu"    = "2"
      "requests.memory" = "4Gi"
      "limits.cpu"      = "8"
      "limits.memory"   = "8Gi"
    }
  }
}

resource "kubernetes_limit_range_v1" "kagent_testbed" {
  for_each = local.kagent_namespaces_enabled ? toset([
    var.kagent_system_namespace,
    var.kagent_testbed_namespace,
  ]) : toset([])

  metadata {
    name      = "container-defaults"
    namespace = each.value
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
}

# v0.9.12 authentication cannot be trusted as a production boundary. The
# controller remains ClusterIP-only and receives traffic solely from its own
# namespace and the integration namespace until an upstream auth fix lands.
resource "kubernetes_network_policy_v1" "kagent_system_default_deny" {
  count = local.kagent_namespaces_enabled ? 1 : 0

  metadata {
    name      = "default-deny-ingress"
    namespace = var.kagent_system_namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy_v1" "kagent_controller_ingress" {
  count = local.kagent_namespaces_enabled ? 1 : 0

  metadata {
    name      = "kagent-controller-ingress"
    namespace = var.kagent_system_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/component" = "controller"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_testbed_namespace }
        }
      }
      ports {
        port     = "8083"
        protocol = "TCP"
      }
      ports {
        port     = "8084"
        protocol = "TCP"
      }
    }

    # Temporal workers use only the in-cluster A2A Gateway. Keep the REST API
    # unavailable to this namespace so the gateway remains the single durable
    # orchestration boundary.
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "yourown-agents" }
        }
      }
      ports {
        port     = "8084"
        protocol = "TCP"
      }
    }
  }
}

# The UI Service remains ClusterIP-only. This policy is additive to the
# namespace default deny and exists only after the cloudflare stack has applied
# a self-hosted Access app, Tunnel ingress and connector token. No other pod or
# namespace receives an ingress path to the UI.
resource "kubernetes_network_policy_v1" "kagent_preview_ui_ingress" {
  count = var.kagent_preview_enabled && var.kagent_preview_ui_access_enabled ? 1 : 0

  metadata {
    name      = "kagent-preview-ui-from-cloudflared"
    namespace = var.kagent_system_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/component" = "ui"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "mcp-tunnel" }
        }
        pod_selector {
          match_labels = { app = "mcp-tunnel" }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

# cloudflared already runs in a default-deny namespace. Open only its egress to
# the exact kagent UI pods and port; the controller REST/gateway Services remain
# unreachable from the Tunnel connector.
resource "kubernetes_network_policy_v1" "cloudflared_to_kagent_preview_ui" {
  count = var.kagent_preview_enabled && var.kagent_preview_ui_access_enabled ? 1 : 0

  metadata {
    name      = "allow-cloudflared-to-kagent-preview-ui"
    namespace = "mcp-tunnel"
  }

  spec {
    pod_selector {
      match_labels = { app = "mcp-tunnel" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/component" = "ui"
          }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

# Cloud Deploy's immutable verification Job is the only intended in-cluster
# exception to the UI's tunnel-only ingress. NetworkPolicy labels are selectors,
# not workload identity; the product render gate therefore locks and validates
# this exact label while the policy keeps the reachable port and namespace small.
resource "kubernetes_network_policy_v1" "kagent_preview_ui_verify_ingress" {
  count = var.kagent_preview_enabled ? 1 : 0

  metadata {
    name      = "kagent-preview-ui-from-verifier"
    namespace = var.kagent_system_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/component" = "ui"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
        pod_selector {
          match_labels = { "platform.yourown.chat/verify" = "kagent-preview" }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

# Selecting the verifier for Egress turns the otherwise ingress-only namespace
# isolation into a strict three-destination policy for this Job: cluster DNS,
# the controller HTTP API and the UI health endpoint.
resource "kubernetes_network_policy_v1" "kagent_preview_verifier_egress" {
  count = var.kagent_preview_enabled ? 1 : 0

  metadata {
    name      = "kagent-preview-verifier-egress"
    namespace = var.kagent_system_namespace
  }

  spec {
    pod_selector {
      match_labels = { "platform.yourown.chat/verify" = "kagent-preview" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/component" = "controller"
          }
        }
      }
      ports {
        port     = "8083"
        protocol = "TCP"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/component" = "ui"
          }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "kagent_database_ingress" {
  count = local.kagent_namespaces_enabled ? 1 : 0

  metadata {
    name      = "kagent-database-ingress"
    namespace = var.kagent_system_namespace
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/component" = "database"
      }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/component" = "controller"
          }
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "kagent_testbed_ingress" {
  count = local.kagent_namespaces_enabled ? 1 : 0

  metadata {
    name      = "kagent-testbed-ingress"
    namespace = var.kagent_testbed_namespace
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_system_namespace }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.kagent_testbed_namespace }
        }
      }
    }
  }
}

# The preview Cloud Deploy execution GSA has only container.clusterViewer in
# Google IAM. All Kubernetes writes are enumerated here and confined to the two
# kagent namespaces, which keeps CRDs and every other cluster-scoped object out
# of its authority.
resource "kubernetes_role_v1" "kagent_preview_deployer" {
  for_each = var.kagent_preview_enabled ? toset([
    var.kagent_system_namespace,
    var.kagent_testbed_namespace,
  ]) : toset([])

  metadata {
    name      = "kagent-preview-deployer"
    namespace = each.value
  }

  rule {
    api_groups = [""]
    resources = [
      "configmaps",
      "persistentvolumeclaims",
      "secrets",
      "serviceaccounts",
      "services",
    ]
    verbs = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["events", "pods", "pods/log"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["kagent.dev"]
    resources  = ["modelconfigs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "kagent_preview_deployer" {
  for_each = kubernetes_role_v1.kagent_preview_deployer

  metadata {
    name      = "kagent-preview-deployer"
    namespace = each.value.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = var.kagent_preview_execution_service_account_email
  }
}

# Terraform owns the controller's exact namespaced runtime RBAC. The product
# assembly excludes the chart RBAC templates, so Cloud Deploy never needs
# roles/rolebindings write, bind or escalate. These rules mirror the locked
# current-main controller contract and remain bounded to the two preview
# namespaces.
resource "kubernetes_role_v1" "kagent_controller_getter" {
  for_each = var.kagent_preview_enabled ? toset([
    var.kagent_system_namespace,
    var.kagent_testbed_namespace,
  ]) : toset([])

  metadata {
    name      = "kagent-preview-getter-role"
    namespace = each.value
  }

  rule {
    api_groups = ["kagent.dev"]
    resources = [
      "harnesses",
      "agenttemplates",
      "sandboxagents",
      "agentharnesses",
      "modelconfigs",
      "modelproviderconfigs",
      "toolservers",
      "memories",
      "remotemcpservers",
      "mcpservers",
    ]
    verbs = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["kagent.dev"]
    resources = [
      "harnesses/finalizers",
      "agenttemplates/finalizers",
      "sandboxagents/finalizers",
      "agentharnesses/finalizers",
      "modelconfigs/finalizers",
      "modelproviderconfigs/finalizers",
      "toolservers/finalizers",
      "memories/finalizers",
      "remotemcpservers/finalizers",
      "mcpservers/finalizers",
    ]
    verbs = ["update"]
  }

  rule {
    api_groups = ["kagent.dev"]
    resources = [
      "harnesses/status",
      "agenttemplates/status",
      "sandboxagents/status",
      "agentharnesses/status",
      "modelconfigs/status",
      "modelproviderconfigs/status",
      "toolservers/status",
      "memories/status",
      "remotemcpservers/status",
      "mcpservers/status",
    ]
    verbs = ["get", "patch", "update"]
  }

  rule {
    api_groups = [""]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["ate.dev"]
    resources  = ["workerpools", "actortemplates"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["ate.dev"]
    resources  = ["actortemplates/status"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["apps", "batch", "gateway.networking.k8s.io", "rbac.authorization.k8s.io"]
    resources  = ["*"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["agents.x-k8s.io"]
    resources  = ["sandboxes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_v1" "kagent_controller_writer" {
  for_each = var.kagent_preview_enabled ? toset([
    var.kagent_system_namespace,
    var.kagent_testbed_namespace,
  ]) : toset([])

  metadata {
    name      = "kagent-preview-writer-role"
    namespace = each.value
  }

  rule {
    api_groups = ["kagent.dev"]
    resources = [
      "harnesses",
      "agenttemplates",
      "sandboxagents",
      "agentharnesses",
      "modelconfigs",
      "modelproviderconfigs",
      "toolservers",
      "memories",
      "remotemcpservers",
      "mcpservers",
    ]
    verbs = ["create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["kagent.dev"]
    resources = [
      "harnesses/finalizers",
      "agenttemplates/finalizers",
      "sandboxagents/finalizers",
      "agentharnesses/finalizers",
      "modelconfigs/finalizers",
      "modelproviderconfigs/finalizers",
      "toolservers/finalizers",
      "memories/finalizers",
      "remotemcpservers/finalizers",
      "mcpservers/finalizers",
    ]
    verbs = ["update"]
  }

  rule {
    api_groups = ["", "apps", "batch", "gateway.networking.k8s.io"]
    resources  = ["*"]
    verbs      = ["create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["agents.x-k8s.io"]
    resources  = ["sandboxes"]
    verbs      = ["create", "update", "patch", "delete"]
  }

  rule {
    api_groups = ["ate.dev"]
    resources  = ["actortemplates"]
    verbs      = ["create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "kagent_controller_getter" {
  for_each = kubernetes_role_v1.kagent_controller_getter

  metadata {
    name      = "kagent-preview-getter-rolebinding"
    namespace = each.value.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.kagent_preview_controller_service_account
    namespace = var.kagent_system_namespace
  }
}

resource "kubernetes_role_binding_v1" "kagent_controller_writer" {
  for_each = kubernetes_role_v1.kagent_controller_writer

  metadata {
    name      = "kagent-preview-writer-rolebinding"
    namespace = each.value.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.kagent_preview_controller_service_account
    namespace = var.kagent_system_namespace
  }
}

resource "kubernetes_role_v1" "kagent_ate_api_env_sources" {
  for_each = var.kagent_preview_enabled ? toset([
    var.kagent_system_namespace,
    var.kagent_testbed_namespace,
  ]) : toset([])

  metadata {
    name      = "kagent-preview-ate-api-env-sources"
    namespace = each.value
  }

  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "kagent_ate_api_env_sources" {
  for_each = kubernetes_role_v1.kagent_ate_api_env_sources

  metadata {
    name      = "kagent-preview-ate-api-env-sources"
    namespace = each.value.metadata[0].namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.kagent_preview_ate_api_service_account.name
    namespace = var.kagent_preview_ate_api_service_account.namespace
  }
}

resource "kubernetes_resource_quota_v1" "server_pilot" {
  for_each = var.server_enabled ? var.server_namespaces : toset([])

  metadata {
    name      = "compute-budget"
    namespace = each.value
  }

  spec {
    hard = {
      "pods"            = "10"
      "requests.cpu"    = "100m"
      "requests.memory" = "256Mi"
      "limits.cpu"      = "2"
      "limits.memory"   = "2Gi"
    }
  }
}

resource "kubernetes_limit_range_v1" "server_pilot" {
  for_each = var.server_enabled ? var.server_namespaces : toset([])

  metadata {
    name      = "container-defaults"
    namespace = each.value
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "250m"
        memory = "256Mi"
      }
      default_request = {
        cpu    = "5m"
        memory = "16Mi"
      }
    }
  }
}

# Cleanup runs as a Cloud Deploy PREDEPLOY hook outside the cluster.
# Long-lived RBAC remains platform policy and grants its dedicated Google
# service accounts permission to scale only the named disposable Deployments.
resource "kubernetes_role_v1" "mattermost_cleanup" {
  metadata {
    name      = "dev-mattermost-cleanup"
    namespace = var.dev_namespace
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments", "deployments/scale"]
    resource_names = ["dev-mattermost", "dev-rtcd"]
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_role_binding_v1" "mattermost_cleanup" {
  metadata {
    name      = "dev-mattermost-cleanup"
    namespace = var.dev_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.mattermost_cleanup.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = var.cleanup_service_account_emails.mattermost
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.cleanup_kubernetes_service_account.name
    namespace = var.cleanup_kubernetes_service_account.namespace
  }
}

resource "kubernetes_role_v1" "mcp_cleanup" {
  metadata {
    name      = "mcp-dev-cleanup"
    namespace = var.dev_namespace
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments", "deployments/scale"]
    resource_names = var.mcp_dev_deployments
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_role_binding_v1" "mcp_cleanup" {
  metadata {
    name      = "mcp-dev-cleanup"
    namespace = var.dev_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.mcp_cleanup.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = var.cleanup_service_account_emails.mcp
  }

  subject {
    kind      = "ServiceAccount"
    name      = var.cleanup_kubernetes_service_account.name
    namespace = var.cleanup_kubernetes_service_account.namespace
  }
}

# Cloud Deploy verification reads only the desired replica count of the pilot
# API. The verifier can therefore distinguish a healthy running release from a
# correctly paused zero-replica release without broad cluster read access.
resource "kubernetes_service_account_v1" "agent_verify" {
  count = var.agent_enabled ? 1 : 0

  metadata {
    name      = "agent-platform-verify"
    namespace = var.agent_namespace
  }
}

resource "kubernetes_role_v1" "agent_verify" {
  count = var.agent_enabled ? 1 : 0

  metadata {
    name      = "agent-platform-verify"
    namespace = var.agent_namespace
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments"]
    resource_names = ["agent-platform-workflow-worker", "agent-platform-activity-worker"]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "agent_verify" {
  count = var.agent_enabled ? 1 : 0

  metadata {
    name      = "agent-platform-verify"
    namespace = var.agent_namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.agent_verify[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent_verify[0].metadata[0].name
    namespace = var.agent_namespace
  }
}
