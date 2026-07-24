resource "kubernetes_service_v1" "this" {
  metadata {
    name      = "dev-postgres"
    namespace = "dev"
    labels    = { app = "dev-postgres" }
  }

  spec {
    cluster_ip = "None"
    selector   = { app = "dev-postgres" }

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_stateful_set_v1" "this" {
  metadata {
    name      = "dev-postgres"
    namespace = "dev"
    labels    = { app = "dev-postgres" }
  }

  spec {
    service_name = kubernetes_service_v1.this.metadata[0].name
    replicas     = 1

    selector {
      match_labels = { app = "dev-postgres" }
    }

    template {
      metadata {
        labels = { app = "dev-postgres" }
      }

      spec {
        automount_service_account_token = false
        priority_class_name             = "development"

        container {
          name  = "postgres"
          image = "postgres:16-alpine"

          env {
            name  = "POSTGRES_USER"
            value = "mmuser"
          }
          env {
            name  = "POSTGRES_DB"
            value = "mattermost"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "dev-postgres"
                key  = "POSTGRES_PASSWORD"
              }
            }
          }
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          port {
            container_port = 5432
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes = ["ReadWriteOnce"]
        resources {
          requests = { storage = "5Gi" }
        }
      }
    }
  }

  depends_on = [kubernetes_service_v1.this]
}
