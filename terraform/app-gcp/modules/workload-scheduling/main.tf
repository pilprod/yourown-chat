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
