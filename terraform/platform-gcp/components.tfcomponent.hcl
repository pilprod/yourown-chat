# PLATFORM stack: the long-lived foundation (APIs, VPC, CMEK, GKE, Cloud SQL,
# storage, registry, Workload Identity SAs). The delivery layer consumes its
# publish_output values from the sibling app-gcp/cloudflare stacks. WI SAs live
# here (not app) so every cross-stack edge points app -> platform, keeping the
# graph acyclic.

locals {
  gke_location = var.gke_regional ? var.region : var.zone

  # Kubernetes tenants (namespace / KSA) that use Workload Identity. Every MCP
  # runtime gets its own identity so CSI-mounted credentials stay isolated.
  ns = {
    mattermost            = { namespace = "mattermost", ksa = "mattermost" }
    matterbridge          = { namespace = "matterbridge", ksa = "matterbridge" }
    dev                   = { namespace = "dev", ksa = "dev-app" }
    mcp                   = { namespace = "mcp-google-cloud", ksa = "mcp-servers" }
    mcp-terraform-stacks  = { namespace = "mcp-terraform-stacks", ksa = "mcp-terraform-stacks" }
    mcp-tunnel            = { namespace = "mcp-tunnel", ksa = "mcp-tunnel" }
  }

  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-platform-gcp"
  }, var.extra_labels)

  # ALL APIs (platform AND app) enabled here, so the two stacks never contend
  # over google_project_service. The bootstrap set is enabled by hand first
  # (README.md).
  activate_apis = [
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
    "cloudbilling.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "billingbudgets.googleapis.com",
    "recommender.googleapis.com",
    "artifactregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    # Keep the API ready for a bounded MCP-controlled scan window. The paid
    # repository gate remains DISABLED during routine builds.
    "containerscanning.googleapis.com",
    "agentregistry.googleapis.com",
    # Official Google-hosted Workspace MCP servers and their underlying APIs.
    "gmail.googleapis.com",
    "gmailmcp.googleapis.com",
    "calendar-json.googleapis.com",
    "calendarmcp.googleapis.com",
    "drive.googleapis.com",
    "drivemcp.googleapis.com",
    # Mattermost Google Workspace sign-in resolves the authenticated profile
    # through People API.
    "people.googleapis.com",
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

# Keyless observability plus guarded release lifecycle for the google-cloud MCP
# server (ADC resolves to this GSA via Workload Identity -- no key, no secret).
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
      "roles/artifactregistry.reader",
      "roles/containeranalysis.occurrences.viewer",
      "roles/cloudbuild.builds.viewer",
      "roles/bigquery.jobUser",
      "roles/recommender.viewer",
      "roles/clouddeploy.releaser",
      "roles/clouddeploy.approver",
    ]
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.gke]
}

component "billing_export" {
  source = "./modules/billing-export"

  inputs = {
    project_id         = component.project_services.project_id
    billing_account_id = var.billing_account_id
    dataset_id         = "billing"
    location           = "EU"
    reader_member      = component.workload_identity_mcp.iam_member
    manager_member     = "serviceAccount:${var.service_account_email}"
    labels             = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

component "billing_budget" {
  source = "./modules/billing-budget"

  inputs = {
    billing_account_id = var.billing_account_id
    display_name       = "YourOwn.Chat monthly USD budget"
    currency_code      = "USD"
    monthly_units      = 100
    actual_thresholds  = [0.5, 0.75, 0.9, 1.0]
    forecast_thresholds = [1.0]
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.project_services]
}

# Disposable dev Google Cloud MCP can inspect observability data but cannot
# promote or approve Cloud Deploy releases.
component "workload_identity_mcp_dev" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "mcp-observability-dev"
    display_name = "Dev Google Cloud MCP observability identity"
    namespace    = local.ns.dev.namespace
    ksa_name     = "mcp-servers"
    project_roles = [
      "roles/logging.viewer",
      "roles/monitoring.viewer",
      "roles/cloudtrace.user",
      "roles/artifactregistry.reader",
      "roles/containeranalysis.occurrences.viewer",
    ]
  }

  providers = {
    google = provider.google.this
  }

  depends_on = [component.gke]
}

# Dedicated identities keep CSI-mounted credentials isolated per MCP server.
# Each identity is also bound to the matching disposable KSA in `dev`.
component "workload_identity_mcp_terraform_stacks" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "mcp-terraform-stacks"
    display_name = "Terraform Stacks MCP Secret Manager identity"
    namespace    = local.ns["mcp-terraform-stacks"].namespace
    ksa_name     = local.ns["mcp-terraform-stacks"].ksa
    additional_ksa_bindings = [{
      namespace = local.ns.dev.namespace
      ksa_name  = local.ns["mcp-terraform-stacks"].ksa
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_mcp_tunnel" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "mcp-tunnel"
    display_name = "Cloudflare MCP Tunnel Secret Manager identity"
    namespace    = local.ns["mcp-tunnel"].namespace
    ksa_name     = local.ns["mcp-tunnel"].ksa
  }

  providers  = { google = provider.google.this }
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

# One shared CMEK key for Cloud SQL, GCS, Secret Manager, GKE etcd, sensitive
# PVCs and opted-in node boot disks (skipped when cmek_enabled = false).
# The public registry and ordinary dev PVCs do not use CMEK.
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
    grant_compute_engine    = true
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
    node_boot_disk_kms_key     = one([for k in component.kms : k.crypto_key_id])
    enable_secret_manager_csi  = true
    deletion_protection        = var.gke_deletion_protection
    resource_labels            = local.common_labels

    # The same shared key protects etcd Secrets and opted-in node boot disks.
    # Referencing kms orders both the key and service-agent grants first.
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

    vulnerability_scanning     = var.artifact_registry_vulnerability_scanning
    scanning_controller_member = component.workload_identity_mcp.iam_member
  }

  providers = {
    google = provider.google.this
  }
}
