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
    resource_names = ["dev-mattermost"]
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
}

resource "kubernetes_role_v1" "mcp_cleanup" {
  for_each = var.mcp_dev_deployments

  metadata {
    name      = "mcp-dev-cleanup"
    namespace = each.key
  }

  rule {
    api_groups     = ["apps"]
    resources      = ["deployments", "deployments/scale"]
    resource_names = [each.value]
    verbs          = ["get", "patch", "update"]
  }
}

resource "kubernetes_role_binding_v1" "mcp_cleanup" {
  for_each = var.mcp_dev_deployments

  metadata {
    name      = "mcp-dev-cleanup"
    namespace = each.key
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.mcp_cleanup[each.key].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = var.cleanup_service_account_emails.mcp
  }
}
