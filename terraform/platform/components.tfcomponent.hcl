# ---------------------------------------------------------------------------
# Component wiring. Each component is a logical platform building block backed
# by a reusable module. Dependencies are expressed by referencing another
# component's outputs, which keeps ordering explicit and coupling loose.
#
# Graph:
#   project_services
#     ├── network ── cloudsql ─┐
#     │           └── gke ── clouddeploy
#     ├── storage ─────────────┤ (accessors)
#     ├── workload_identity_{mattermost,matterbridge,dev} ┘
#     └── secrets
#
# The container registry and image CI are NOT in this stack: they live in the
# separate build stack (terraform/build), which owns the unified docker
# repository. This stack only enables the artifactregistry/cloudbuild APIs (see
# activate_apis) so the build stack can create the registry and the GKE nodes
# can pull from it (the node SA gets project-level artifactregistry.reader).
#
# Workload Identity SAs are created first (they only need the APIs enabled) and
# their IAM member strings are passed as least-privilege secretAccessors to the
# secret-owning components (cloudsql, storage, secrets). This keeps every
# credential in Secret Manager and readable only by the exact workload.
# ---------------------------------------------------------------------------

locals {
  # Tier-neutral prefix for every platform resource (yourown-chat-*), matching the
  # KMS key and Cloud Deploy pipeline. environment drives labels, not names: this is
  # a single-deployment platform and "dev" is a tenant namespace, so an environment
  # segment in names would only collide with the dev tenant (it would produce the
  # contradictory yourown-chat-prod-dev). Reintroduce
  # "${var.project_prefix}-${var.environment}" here if you ever run two deployments
  # in one project.
  name_prefix  = var.project_prefix
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
    stack       = "yourown-chat-platform"
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
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "clouddeploy.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ]
}

component "project_services" {
  source = "./modules/project-services"

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
  source = "./modules/workload-identity"

  inputs = {
    project_id = component.project_services.project_id
    # The prod Mattermost IS the product, so its identity is the bare project
    # prefix (yourown-chat); the dev copy is yourown-chat-dev, the bridge -br.
    account_id   = substr(local.name_prefix, 0, 30)
    display_name = "Mattermost (prod) workload identity"
    namespace    = local.ns.mattermost.namespace
    ksa_name     = local.ns.mattermost.ksa
  }

  providers = {
    google = provider.google.this
  }
}

component "workload_identity_matterbridge" {
  source = "./modules/workload-identity"

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
  source = "./modules/workload-identity"

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
  source = "./modules/secrets"

  inputs = {
    project_id        = component.project_services.project_id
    replica_locations = [var.region]
    labels            = local.common_labels

    # CMEK: shared platform key encrypts every secret replica (null when
    # cmek_enabled = false, i.e. the kms component is absent).
    kms_key_name = one([for k in component.kms : k.crypto_key_id])

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
  source = "./modules/network"

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

# --- Shared CMEK key (Cloud SQL + GCS + Artifact Registry) -------------------
# One customer-managed Cloud KMS key wraps the data-encryption keys of every
# at-rest store that supports CMEK. Gated by cmek_enabled; when false the
# component is skipped and each store falls back to Google-managed keys. The
# build stack's Artifact Registry references THIS key by its deterministic
# resource path and relies on the encrypterDecrypter grant created here, so the
# platform stack must be applied first (already the documented ordering).
component "kms" {
  for_each = var.cmek_enabled ? toset(["default"]) : toset([])

  source = "./modules/kms"

  inputs = {
    project_id = component.project_services.project_id
    # Tier-neutral name (yourown-chat-*), like the Cloud Deploy pipeline below:
    # the key is shared by prod Cloud SQL/GCS and the cross-environment registry,
    # so it is not scoped to the per-environment platform prefix.
    name_prefix      = var.project_prefix
    location         = var.region
    protection_level = var.kms_protection_level
    rotation_period  = var.kms_rotation_period
    labels           = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

# --- Object storage + Mattermost S3-compatible filestore credentials --------
component "storage" {
  source = "./modules/storage"

  inputs = {
    project_id    = component.project_services.project_id
    name_prefix   = local.name_prefix
    location      = upper(var.region)
    force_destroy = var.storage_force_destroy
    labels        = local.common_labels

    # CMEK: shared platform key (null when cmek_enabled = false).
    kms_key_name = one([for k in component.kms : k.crypto_key_id])

    create_filestore_hmac      = true
    filestore_secret_accessors = [component.workload_identity_mattermost.iam_member]
    secret_replica_locations   = [var.region]
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- GKE: one zonal cluster, two node pools (prod tainted + dev) ------------
component "gke" {
  source = "./modules/gke"

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

  source = "./modules/cloudsql"

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

    # CMEK: shared platform key (null when cmek_enabled = false). The key's
    # encrypterDecrypter grant for the Cloud SQL service agent is created by the
    # kms component; referencing it here orders that grant before this instance.
    encryption_key_name = one([for k in component.kms : k.crypto_key_id])

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
# Cloud Deploy governs promotion of the platform's Kubernetes workloads (helm/)
# as a managed dev -> prod pipeline: two targets on the ONE cluster, each
# rendering a Skaffold profile from helm/skaffold.yaml.
#   dev  - the dev tenant (in-cluster Postgres + dev Mattermost) and matterbridge,
#          followed by an on-cluster post-deploy `verify` smoke test.
#   prod - the operator-managed prod Mattermost, gated by manual approval.
# Both targets share the ONE cluster; which namespaces/workloads each applies
# comes entirely from its Skaffold profile, not a separate cluster. The Mattermost
# image is built once by the build stack (terraform/build) and promoted by tag
# (build-once/promote-the-same-tag); Cloud Deploy promotes the SAME manifests
# dev -> prod. The pipeline spans both tiers; its resources (pipeline, targets,
# execution SA) use bare project-scoped names (pipeline, dev, prod, clouddeploy)
# rather than repeating the project prefix.
component "clouddeploy" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = component.project_services.project_id
    region         = var.region
    gke_cluster_id = component.gke.cluster_id

    # Ordered promotion flow; profiles bind to helm/skaffold.yaml. dev verifies
    # after deploy; prod requires manual approval before it is promoted.
    stages = [
      { name = "dev", profiles = ["dev"], require_approval = false, verify = true },
      { name = "prod", profiles = ["prod"], require_approval = true, verify = false },
    ]

    labels = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}
