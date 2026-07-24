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
