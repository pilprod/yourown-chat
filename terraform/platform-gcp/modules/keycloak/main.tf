locals {
  labels = merge(var.labels, {
    "app.kubernetes.io/name"       = "keycloak"
    "app.kubernetes.io/part-of"    = "yourown-chat-platform"
    "app.kubernetes.io/managed-by" = "terraform"
  })
}

# Preserve an operator-recoverable copy without exposing it as a Stack output.
# The running pod receives the same value through a CMEK-encrypted Kubernetes
# Secret; it does not need Secret Manager access or a Google service account.
resource "google_secret_manager_secret" "bootstrap_admin" {
  count     = var.enabled ? 1 : 0
  project   = var.project_id
  secret_id = "keycloak-bootstrap-admin-client-secret"
  labels    = var.labels

  replication {
    user_managed {
      replicas {
        location = var.region
        dynamic "customer_managed_encryption" {
          for_each = var.encryption_key_name == null ? [] : [var.encryption_key_name]
          content { kms_key_name = customer_managed_encryption.value }
        }
      }
    }
  }
}

ephemeral "google_secret_manager_secret_version" "bootstrap_admin" {
  count   = var.enabled ? 1 : 0
  project = var.project_id
  secret  = google_secret_manager_secret.bootstrap_admin[0].secret_id
  version = "latest"
}

resource "kubernetes_namespace_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name = var.namespace
    labels = merge(local.labels, {
      tier                                      = "platform"
      component                                 = "identity"
      "pod-security.kubernetes.io/enforce"     = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"       = "restricted"
      "pod-security.kubernetes.io/warn"        = "restricted"
    })
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "compute-budget"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
  }
  spec {
    hard = {
      pods              = "8"
      "requests.cpu"    = "500m"
      "requests.memory" = "1Gi"
      "limits.cpu"      = "2"
      "limits.memory"   = "2Gi"
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
      default         = { cpu = "1", memory = "1536Mi" }
      default_request = { cpu = "250m", memory = "768Mi" }
    }
  }
}

resource "kubernetes_service_account_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }
  automount_service_account_token = false
}

resource "kubernetes_secret_v1" "runtime" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "keycloak-runtime"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }
  data_wo = {
    "database-password"       = var.database_password
    "bootstrap-client-secret" = ephemeral.google_secret_manager_secret_version.bootstrap_admin[0].secret_data
  }
  data_wo_revision = tonumber(var.bootstrap_secret_version)
  type = "Opaque"
}

resource "kubernetes_service_v1" "cloudsql" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "keycloak-cloudsql"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }
  spec {
    port {
      name = "postgres"
      port = 5432
      target_port = 5432
      protocol = "TCP"
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

resource "kubernetes_service_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = { "app.kubernetes.io/name" = "keycloak" }
    port {
      name        = "http"
      port        = 8080
      target_port = "http"
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_network_policy_v1" "isolation" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "keycloak-isolation"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }
  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "keycloak" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "ingress-nginx" }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "yourown-chat-server" }
        }
      }
      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
        pod_selector {
          match_labels = { "k8s-app" = "kube-dns" }
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
    # Identity brokering, mail delivery and certificate validation use TLS.
    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "this" {
  count = var.enabled ? 1 : 0
  metadata {
    name      = "keycloak"
    namespace = kubernetes_namespace_v1.this[0].metadata[0].name
    labels    = local.labels
  }
  spec {
    replicas = 1
    selector { match_labels = { "app.kubernetes.io/name" = "keycloak" } }
    strategy { type = "Recreate" }
    template {
      metadata { labels = local.labels }
      spec {
        service_account_name            = kubernetes_service_account_v1.this[0].metadata[0].name
        automount_service_account_token = false
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "keycloak"
          image             = "quay.io/keycloak/keycloak:${var.image_version}"
          image_pull_policy = "IfNotPresent"
          # Preserve the tail of stdout in Pod status when startup fails. This
          # keeps pilot diagnostics available even while cost-saving cluster
          # configuration collects only Kubernetes system logs.
          termination_message_policy = "FallbackToLogsOnError"
          args              = ["start"]

          env {
            name  = "KC_DB"
            value = "postgres"
          }
          env {
            name  = "KC_DB_URL"
            value = "jdbc:postgresql://keycloak-cloudsql.${var.namespace}.svc.cluster.local:5432/keycloak?sslmode=require"
          }
          env {
            name  = "KC_DB_USERNAME"
            value = "keycloak"
          }
          env {
            name = "KC_DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.runtime[0].metadata[0].name
                key  = "database-password"
              }
            }
          }
          env {
            name  = "KC_BOOTSTRAP_ADMIN_CLIENT_ID"
            value = "bootstrap-admin"
          }
          env {
            name = "KC_BOOTSTRAP_ADMIN_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.runtime[0].metadata[0].name
                key  = "bootstrap-client-secret"
              }
            }
          }
          env {
            name  = "KC_HOSTNAME"
            value = var.public_url
          }
          env {
            name  = "KC_HOSTNAME_BACKCHANNEL_DYNAMIC"
            value = "true"
          }
          env {
            name  = "KC_HOSTNAME_STRICT"
            value = "false"
          }
          env {
            name  = "KC_HTTP_ENABLED"
            value = "true"
          }
          env {
            name  = "KC_HTTP_RELATIVE_PATH"
            value = "/auth"
          }
          env {
            name  = "KC_PROXY_HEADERS"
            value = "xforwarded"
          }
          env {
            name  = "KC_HEALTH_ENABLED"
            value = "true"
          }
          env {
            name  = "KC_METRICS_ENABLED"
            value = "true"
          }
          env {
            name  = "KC_FEATURES"
            value = "passkeys"
          }

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          port {
            name           = "management"
            container_port = 9000
            protocol       = "TCP"
          }

          startup_probe {
            http_get {
              path   = "/health/started"
              port   = "management"
              scheme = "HTTP"
            }
            period_seconds = 5
            failure_threshold = 60
          }
          readiness_probe {
            http_get {
              path   = "/health/ready"
              port   = "management"
              scheme = "HTTP"
            }
            period_seconds = 10
            failure_threshold = 6
          }
          liveness_probe {
            http_get {
              path   = "/health/live"
              port   = "management"
              scheme = "HTTP"
            }
            period_seconds = 20
            failure_threshold = 3
          }
          resources {
            requests = { cpu = "250m", memory = "768Mi" }
            limits   = { cpu = "1", memory = "1536Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            # The upstream image performs its Quarkus augmentation on the
            # first `start`. Keep the process non-root, capability-free and
            # seccomp-confined, but allow that one container-local write. A
            # platform-built optimized image can switch this back to true.
            read_only_root_filesystem  = false
            run_as_non_root            = true
            capabilities { drop = ["ALL"] }
          }
          volume_mount {
            name       = "keycloak-data"
            mount_path = "/opt/keycloak/data"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
        }
        volume {
          name = "keycloak-data"
          empty_dir {}
        }
        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [
    kubernetes_resource_quota_v1.this,
    kubernetes_limit_range_v1.this,
    kubernetes_network_policy_v1.isolation,
    kubernetes_endpoints_v1.cloudsql,
  ]
}
