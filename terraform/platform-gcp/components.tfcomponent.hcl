# PLATFORM stack: the long-lived foundation (APIs, VPC, CMEK, GKE, Cloud SQL,
# storage, registry, Workload Identity SAs). The delivery layer consumes its
# publish_output values from the sibling app-gcp/cloudflare stacks. WI SAs live
# here (not app) so every cross-stack edge points app -> platform, keeping the
# graph acyclic.

locals {
  gke_location = var.gke_regional ? var.region : var.zone

  # Kubernetes tenants (namespace / KSA) that consume GCP secrets. The Google
  # Cloud MCP server alone needs a GCP identity, and gets its own namespace.
  ns = {
    mattermost   = { namespace = "mattermost", ksa = "mattermost" }
    matterbridge = { namespace = "matterbridge", ksa = "matterbridge" }
    dev          = { namespace = "dev", ksa = "dev-app" }
    mcp          = { namespace = "mcp-google-cloud", ksa = "mcp-servers" }
  }

  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-platform-gcp"
  }, var.extra_labels)

  # ALL APIs (platform AND app) enabled here, so the two stacks never contend
  # over google_project_service. The bootstrap set is enabled by hand first
  # (README.md).
  activate_apis = concat([
    "compute.googleapis.com",
    "container.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "cloudkms.googleapis.com",
    "storage.googleapis.com",
    "clouddeploy.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    ],
    var.artifact_registry_vulnerability_scanning ? ["containerscanning.googleapis.com"] : []
  )
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

# Workload Identity SAs. depends_on component.gke: the PROJECT.svc.id.goog pool
# the workloadIdentityUser binding references only exists once a WI-enabled
# cluster is created.
component "workload_identity_mattermost" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "mattermost"
    display_name = "Mattermost (prod) workload identity"
    namespace    = local.ns.mattermost.namespace
    ksa_name     = local.ns.mattermost.ksa
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.gke]
}

component "workload_identity_matterbridge" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "matterbridge"
    display_name = "matterbridge workload identity"
    namespace    = local.ns.matterbridge.namespace
    ksa_name     = local.ns.matterbridge.ksa
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.gke]
}

component "workload_identity_dev" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "mattermost-dev"
    display_name = "Dev tenant workload identity"
    namespace    = local.ns.dev.namespace
    ksa_name     = local.ns.dev.ksa
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.gke]
}

# Keyless read-only observability for the google-cloud MCP server (ADC resolves
# to this GSA via Workload Identity -- no key, no secret).
component "workload_identity_mcp" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "mcp-servers"
    display_name = "Google Cloud MCP workload identity"
    namespace    = local.ns.mcp.namespace
    ksa_name     = local.ns.mcp.ksa
    project_roles = [
      "roles/logging.viewer",
      "roles/monitoring.viewer",
      "roles/cloudtrace.user",
    ]
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.gke]
}

component "network" {
  source = "./modules/network"

  inputs = {
    project_id = component.project_services.project_id
    region     = var.region
    labels     = local.common_labels

    # Reserve the Cloudflare-facing static IP only where a public ingress exists.
    ingress_static_ip = var.public_ingress_enabled
  }

  providers = {
    google = provider.google.this
  }
}

# One shared CMEK key for Cloud SQL + GCS + Secret Manager (skipped when
# cmek_enabled = false -> Google-managed keys). grant_gke lets the GKE agent
# use it for etcd application-layer Secrets encryption. The public registry
# does not use CMEK.
component "kms" {
  for_each = var.cmek_enabled ? toset(["default"]) : toset([])

  source = "./modules/kms"

  inputs = {
    project_id       = component.project_services.project_id
    location         = var.region
    protection_level = var.kms_protection_level
    rotation_period  = var.kms_rotation_period
    labels           = local.common_labels

    # KMS objects are never deletable in GCP: adopt the pre-existing ring/key.
    adopt_existing = var.kms_adopt_existing

    grant_artifact_registry = false
    grant_gke               = true
    project_number          = var.project_number
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

component "storage" {
  source = "./modules/storage"

  inputs = {
    project_id    = component.project_services.project_id
    location      = upper(var.region)
    force_destroy = var.storage_force_destroy
    labels        = local.common_labels

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

component "gke" {
  source = "./modules/gke"

  inputs = {
    project_id                 = component.project_services.project_id
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

    # etcd Secrets encryption with the shared CMEK key (null omits the block ->
    # Google-managed); referencing kms orders the key + its GKE-agent grant first.
    database_encryption_key = one([for k in component.kms : k.crypto_key_id])
  }

  providers = {
    google = provider.google.this
  }
}

# Prod-only (dev uses an in-cluster StatefulSet).
component "cloudsql" {
  for_each = var.cloudsql_enabled ? toset(["default"]) : toset([])

  source = "./modules/cloudsql"

  inputs = {
    project_id                    = component.project_services.project_id
    region                        = var.region
    zone                          = var.zone
    network_id                    = component.network.network_id
    private_service_connection_id = component.network.private_service_connection_id
    tier                          = var.cloudsql_tier
    availability_type             = var.cloudsql_availability_type
    disk_size_gb                  = var.cloudsql_disk_size_gb
    deletion_protection           = var.cloudsql_deletion_protection
    adopt_existing_instance       = var.cloudsql_adopt_existing_instance

    encryption_key_name = one([for k in component.kms : k.crypto_key_id])

    database_name = "mattermost"
    db_user_name  = "mattermost"

    backup_enabled                 = true
    point_in_time_recovery_enabled = var.cloudsql_pitr_enabled
    backup_retained_count          = var.cloudsql_backup_retained_count
    transaction_log_retention_days = var.cloudsql_txlog_retention_days

    create_connection_secret    = true
    connection_secret_accessors = [component.workload_identity_mattermost.iam_member]

    password_rotation = var.cloudsql_password_rotation

    user_labels = local.common_labels
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

component "artifact_registry" {
  source = "./modules/artifact-registry"

  inputs = {
    project_id    = component.project_services.project_id
    location      = var.region
    repository_id = var.artifact_registry_repository_id
    description   = "Unified container images (Mattermost + future services), promoted by tag across environments."
    kms_key_name  = var.artifact_registry_kms_key_name
    labels        = local.common_labels

    vulnerability_scanning = var.artifact_registry_vulnerability_scanning
  }

  providers = {
    google = provider.google.this
  }
}
