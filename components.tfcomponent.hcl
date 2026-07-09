# ---------------------------------------------------------------------------
# Component wiring. Each component is a logical platform building block backed
# by a reusable module. Dependencies are expressed by referencing another
# component's outputs, which keeps ordering explicit and coupling loose.
#
# Graph:
#   project_services
#     ├── network ── cloudsql ─┐
#     │           └── gke      │ (accessors)
#     ├── storage ─────────────┤
#     ├── artifact_registry ── (clouddeploy, cloudbuild)
#     ├── workload_identity_{mattermost,matterbridge,dev} ┘
#     └── secrets
#
# Workload Identity SAs are created first (they only need the APIs enabled) and
# their IAM member strings are passed as least-privilege secretAccessors to the
# secret-owning components (cloudsql, storage, secrets). This keeps every
# credential in Secret Manager and readable only by the exact workload.
# ---------------------------------------------------------------------------

locals {
  name_prefix  = "${var.project_prefix}-${var.environment}"
  gke_location = var.gke_regional ? var.region : var.zone

  # Kubernetes tenants (namespace / service account) that consume GCP secrets.
  ns = {
    mattermost   = { namespace = "mattermost", ksa = "mattermost" }
    matterbridge = { namespace = "matterbridge", ksa = "matterbridge" }
    dev          = { namespace = "dev", ksa = "dev-app" }
  }

  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-stack"
  }, var.extra_labels)

  activate_apis = [
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "clouddeploy.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]
}

component "project_services" {
  source = "./infra/modules/project-services"

  inputs = {
    project_id    = var.project_id
    activate_apis = local.activate_apis
  }

  providers = {
    google = provider.google.this
  }
}

# --- Workload Identity service accounts (per tenant) ------------------------
component "workload_identity_mattermost" {
  source = "./infra/modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = substr("${local.name_prefix}-mm", 0, 30)
    display_name = "Mattermost (prod) workload identity"
    namespace    = local.ns.mattermost.namespace
    ksa_name     = local.ns.mattermost.ksa
  }

  providers = {
    google = provider.google.this
  }
}

component "workload_identity_matterbridge" {
  source = "./infra/modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = substr("${local.name_prefix}-br", 0, 30)
    display_name = "matterbridge workload identity"
    namespace    = local.ns.matterbridge.namespace
    ksa_name     = local.ns.matterbridge.ksa
  }

  providers = {
    google = provider.google.this
  }
}

component "workload_identity_dev" {
  source = "./infra/modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = substr("${local.name_prefix}-dev", 0, 30)
    display_name = "Dev tenant workload identity"
    namespace    = local.ns.dev.namespace
    ksa_name     = local.ns.dev.ksa
  }

  providers = {
    google = provider.google.this
  }
}

# --- Additional application secrets (all credentials live in Secret Manager) -
component "secrets" {
  source = "./infra/modules/secrets"

  inputs = {
    project_id        = component.project_services.project_id
    name_prefix       = local.name_prefix
    replica_locations = [var.region]
    labels            = local.common_labels

    secrets = merge(
      {
        # In-cluster dev Postgres password (generated, read by the dev tenant).
        "dev-postgres-password" = {
          generate  = true
          accessors = [component.workload_identity_dev.iam_member]
        }
        # matterbridge bot tokens / bridge config — created empty, populated
        # out-of-band (never in git), read by the matterbridge workload.
        "matterbridge-tokens" = {
          accessors = [component.workload_identity_matterbridge.iam_member]
        }
      },
      # Cloudflare origin-protection material for the public ingress (prod only).
      # Empty containers; the PEM values are added out-of-band (never in git) and
      # read only by the Mattermost workload, which materialises them via the CSI
      # driver so ingress-nginx can (a) serve the Cloudflare Origin CA cert for
      # Full (Strict) TLS and (b) verify the client cert Cloudflare presents for
      # Authenticated Origin Pulls (mTLS) -- closing the shared-Cloudflare-IP gap.
      var.public_ingress_enabled ? {
        "mattermost-origin-tls-cert" = {
          accessors = [component.workload_identity_mattermost.iam_member]
        }
        "mattermost-origin-tls-key" = {
          accessors = [component.workload_identity_mattermost.iam_member]
        }
        "cloudflare-origin-pull-ca" = {
          accessors = [component.workload_identity_mattermost.iam_member]
        }
      } : {}
    )
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Networking -------------------------------------------------------------
component "network" {
  source = "./infra/modules/network"

  inputs = {
    project_id  = component.project_services.project_id
    name_prefix = local.name_prefix
    region      = var.region
    labels      = local.common_labels

    # Reserve the Cloudflare-facing static IP only where a public ingress exists.
    ingress_static_ip = var.public_ingress_enabled
  }

  providers = {
    google = provider.google.this
  }
}

# --- Object storage + Mattermost S3-compatible filestore credentials --------
component "storage" {
  source = "./infra/modules/storage"

  inputs = {
    project_id    = component.project_services.project_id
    name_prefix   = "${local.name_prefix}-app"
    location      = upper(var.region)
    force_destroy = var.storage_force_destroy
    labels        = local.common_labels

    create_filestore_hmac      = true
    filestore_secret_accessors = [component.workload_identity_mattermost.iam_member]
    secret_replica_locations   = [var.region]
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Container image registry ----------------------------------------------
component "artifact_registry" {
  source = "./infra/modules/artifact-registry"

  inputs = {
    project_id    = component.project_services.project_id
    location      = var.region
    repository_id = "${local.name_prefix}-containers"
    labels        = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# --- GKE: one zonal cluster, two node pools (prod tainted + dev) ------------
component "gke" {
  source = "./infra/modules/gke"

  inputs = {
    project_id                 = component.project_services.project_id
    name_prefix                = local.name_prefix
    location                   = local.gke_location
    network_id                 = component.network.network_id
    subnet_id                  = component.network.subnet_id
    pods_range_name            = component.network.pods_range_name
    services_range_name        = component.network.services_range_name
    master_authorized_networks = var.master_authorized_networks
    node_pools                 = var.gke_node_pools
    enable_secret_manager_csi  = true
    deletion_protection        = var.gke_deletion_protection
    resource_labels            = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# --- Managed Postgres (prod) + connection secret ----------------------------
component "cloudsql" {
  # Skipped entirely when cloudsql_enabled = false (e.g. dev, which uses the
  # in-cluster Postgres StatefulSet). Only the stack outputs consume this
  # component, so gating it here has no cross-component ripple.
  for_each = var.cloudsql_enabled ? toset(["default"]) : toset([])

  source = "./infra/modules/cloudsql"

  inputs = {
    project_id                    = component.project_services.project_id
    name_prefix                   = local.name_prefix
    region                        = var.region
    network_id                    = component.network.network_id
    private_service_connection_id = component.network.private_service_connection_id
    tier                          = var.cloudsql_tier
    availability_type             = var.cloudsql_availability_type
    disk_size_gb                  = var.cloudsql_disk_size_gb
    deletion_protection           = var.cloudsql_deletion_protection

    database_name = "mattermost"
    db_user_name  = "mattermost"

    backup_enabled                 = true
    point_in_time_recovery_enabled = var.cloudsql_pitr_enabled
    backup_retained_count          = var.cloudsql_backup_retained_count
    transaction_log_retention_days = var.cloudsql_txlog_retention_days

    # Publish a ready-to-use connection URI to Secret Manager and let only the
    # Mattermost workload read it.
    create_connection_secret    = true
    connection_secret_accessors = [component.workload_identity_mattermost.iam_member]

    user_labels = local.common_labels
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Continuous delivery ----------------------------------------------------
component "clouddeploy" {
  source = "./infra/modules/clouddeploy"

  inputs = {
    project_id     = component.project_services.project_id
    name_prefix    = local.name_prefix
    region         = var.region
    gke_cluster_id = component.gke.cluster_id
    labels         = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

component "cloudbuild" {
  source = "./infra/modules/cloudbuild"

  inputs = {
    project_id                      = component.project_services.project_id
    name_prefix                     = local.name_prefix
    artifact_registry_location      = component.artifact_registry.location
    artifact_registry_repository_id = component.artifact_registry.repository_id
    clouddeploy_execution_sa_email  = component.clouddeploy.execution_service_account_email
  }

  providers = {
    google = provider.google.this
  }
}
