locals {
  labels = merge(var.labels, {
    "app.kubernetes.io/name"       = "keycloak"
    "app.kubernetes.io/part-of"    = "yourown-chat-platform"
    "app.kubernetes.io/managed-by" = "terraform"
  })
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
      default_request = { cpu = "100m", memory = "640Mi" }
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
    "database-password" = var.database_password
  }
  data_wo_revision = 2
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
    port {
      name        = "https"
      port        = 8443
      target_port = "https"
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
        port     = "8443"
        protocol = "TCP"
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      # GKE Dataplane V2 evaluates Service traffic against the pre-DNAT
      # ClusterIP. NodeLocal DNSCache is host-networked and cannot be selected
      # reliably as a normal kube-dns Pod, so keep the namespace rule constrained
      # to DNS ports and explicitly allow the kube-dns virtual IP as well.
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
  wait_for_rollout = false
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
            name  = "KC_HOSTNAME"
            value = var.public_url
          }
          env {
            name  = "KC_HOSTNAME_BACKCHANNEL_DYNAMIC"
            value = "true"
          }
          env {
            name  = "KC_HOSTNAME_STRICT"
            value = "true"
          }
          env {
            name  = "KC_HTTP_ENABLED"
            value = "true"
          }
          env {
            name  = "KC_HTTPS_CERTIFICATE_FILE"
            value = "/var/run/secrets/keycloak-tls/tls.crt"
          }
          env {
            name  = "KC_HTTPS_CERTIFICATE_KEY_FILE"
            value = "/var/run/secrets/keycloak-tls/tls.key"
          }
          env {
            name  = "KC_HTTP_RELATIVE_PATH"
            value = "/"
          }
          # Keep health and metrics on the private management listener.
          env {
            name  = "KC_HTTP_MANAGEMENT_RELATIVE_PATH"
            value = "/"
          }
          # Keep the private management listener on plain HTTP so Kubernetes
          # probes do not inherit the public listener's TLS configuration.
          # Port 9000 is not exposed by the Service or any ingress.
          env {
            name  = "KC_HTTP_MANAGEMENT_SCHEME"
            value = "http"
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
          port {
            name           = "https"
            container_port = 8443
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
            # Pilot baseline: observed steady-state usage is well below the CPU
            # reservation and around 500Mi of memory. Keep startup headroom in
            # the limits while avoiding unnecessary node reservation.
            requests = { cpu = "100m", memory = "640Mi" }
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
          volume_mount {
            name       = "keycloak-tls"
            mount_path = "/var/run/secrets/keycloak-tls"
            read_only  = true
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
        volume {
          name = "keycloak-tls"
          secret {
            secret_name = "keycloak-internal-tls"
          }
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
