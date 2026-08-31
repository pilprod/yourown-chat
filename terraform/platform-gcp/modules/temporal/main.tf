locals {
  labels = merge(var.labels, {
    "app.kubernetes.io/name"       = "temporal"
    "app.kubernetes.io/part-of"    = "yourown-chat-platform"
    "app.kubernetes.io/managed-by" = "terraform"
  })
}

resource "kubernetes_namespace_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      tier      = "platform"
      component = "orchestration"
    })
  }
}

resource "kubernetes_secret_v1" "database" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "temporal-db"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }

  data = { password = var.database_password }
}

resource "kubernetes_resource_quota_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "compute-budget"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }

  spec {
    hard = {
      "pods"            = "25"
      "requests.cpu"    = "750m"
      "requests.memory" = "3Gi"
      "limits.cpu"      = "4"
      "limits.memory"   = "6Gi"
    }
  }
}

resource "kubernetes_limit_range_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "container-defaults"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
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

resource "kubernetes_service_v1" "cloudsql" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "temporal-cloudsql"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }

  spec {
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_endpoints_v1" "cloudsql" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = kubernetes_service_v1.cloudsql[0].metadata[0].name
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }

  subset {
    address { ip = var.cloudsql_private_ip }
    port {
      name     = "postgres"
      port     = 5432
      protocol = "TCP"
    }
  }
}

resource "kubernetes_network_policy_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "temporal-platform-isolation"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.namespace }
        }
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = var.namespace }
        }
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      # NodeLocal DNSCache is host-networked under Dataplane V2. Permit only DNS
      # ports from kube-system and pin the virtual kube-dns address as well.
      to {
        ip_block {
          cidr = "${var.cluster_dns_ip}/32"
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
        ip_block {
          cidr = "${var.cloudsql_private_ip}/32"
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}

resource "helm_release" "this" {
  count = var.enabled ? 1 : 0

  name       = "temporal"
  repository = "https://go.temporal.io/helm-charts"
  chart      = "temporal"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.this[0].metadata[0].name

  values = [yamlencode({
    serviceAccount = { create = true, name = "temporal-server" }
    server = {
      enabled      = true
      replicaCount = 1
      resources    = { requests = { cpu = "25m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
      config = {
        logLevel = "info"
        persistence = {
          defaultStore = "default", visibilityStore = "visibility", numHistoryShards = 4
          datastores = {
            default = { sql = {
              createDatabase = false, manageSchema = true, pluginName = "postgres12_pgx", driverName = "postgres12_pgx"
              databaseName   = "temporal", connectAddr = "temporal-cloudsql.${var.namespace}.svc.cluster.local:5432", connectProtocol = "tcp"
              user           = "temporal", existingSecret = kubernetes_secret_v1.database[0].metadata[0].name, secretKey = "password", maxConns = 5, maxIdleConns = 1
              tls            = { enabled = true, enableHostVerification = false }
            } }
            visibility = { sql = {
              createDatabase = false, manageSchema = true, pluginName = "postgres12_pgx", driverName = "postgres12_pgx"
              databaseName   = "temporal_visibility", connectAddr = "temporal-cloudsql.${var.namespace}.svc.cluster.local:5432", connectProtocol = "tcp"
              user           = "temporal", existingSecret = kubernetes_secret_v1.database[0].metadata[0].name, secretKey = "password", maxConns = 3, maxIdleConns = 1
              tls            = { enabled = true, enableHostVerification = false }
            } }
          }
        }
        namespaces = { create = true, namespace = [{ name = "yourown-chat", retention = "7d" }] }
      }
      frontend = { resources = { requests = { cpu = "25m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } } }
      history  = { resources = { requests = { cpu = "25m", memory = "192Mi" }, limits = { cpu = "500m", memory = "768Mi" } } }
      matching = { resources = { requests = { cpu = "15m", memory = "96Mi" }, limits = { cpu = "300m", memory = "384Mi" } } }
      worker   = { resources = { requests = { cpu = "15m", memory = "96Mi" }, limits = { cpu = "300m", memory = "384Mi" } } }
    }
    admintools = { enabled = false }
    web        = { enabled = false }
    schema = {
      # The official chart explicitly recommends ordinary managed Jobs when
      # the Helm release lifecycle is owned by Terraform.
      useHelmHooks = false, backoffLimit = 10, ttlSecondsAfterFinished = 600
      resources    = { requests = { cpu = "25m", memory = "64Mi" }, limits = { cpu = "250m", memory = "256Mi" } }
    }
    shims = { dockerize = false, elasticsearchTool = false }
  })]

  atomic          = true
  cleanup_on_fail = true
  wait            = true
  timeout         = 900

  depends_on = [
    kubernetes_secret_v1.database,
    kubernetes_resource_quota_v1.this,
    kubernetes_limit_range_v1.this,
    kubernetes_service_v1.cloudsql,
    kubernetes_endpoints_v1.cloudsql,
    kubernetes_network_policy_v1.this,
  ]
}
