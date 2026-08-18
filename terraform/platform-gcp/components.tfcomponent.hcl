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
    mattermost           = { namespace = "mattermost", ksa = "mattermost" }
    matterbridge         = { namespace = "matterbridge", ksa = "matterbridge" }
    dev                  = { namespace = "dev", ksa = "dev-app" }
    mcp                  = { namespace = "mcp-google-cloud", ksa = "mcp-servers" }
    mcp-terraform-stacks = { namespace = "mcp-terraform-stacks", ksa = "mcp-terraform-stacks" }
    mcp-tunnel           = { namespace = "mcp-tunnel", ksa = "mcp-tunnel" }
    backend-control-api   = { namespace = "server-control", ksa = "control" }
    auth-api              = { namespace = "server-edge", ksa = "auth" }
    transport-api         = { namespace = "server-edge", ksa = "transport" }
    identity-api          = { namespace = "server-identity", ksa = "api" }
    identity-admin        = { namespace = "server-identity", ksa = "admin" }
    identity-migrate      = { namespace = "server-identity", ksa = "migrate" }
    agents-workflow      = { namespace = "yourown-agents", ksa = "agent-workflow-worker" }
    agents-activity      = { namespace = "yourown-agents", ksa = "agent-activity-worker" }
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
    "ondemandscanning.googleapis.com",
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
    billing_account_id  = var.billing_account_id
    project_number      = var.project_number
    display_name        = "YourOwn.Chat monthly USD budget"
    currency_code       = "USD"
    monthly_units       = 200
    actual_thresholds   = [0.5, 0.75, 0.9, 1.0]
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

# Keep these declarations for one applied configuration after retiring the
# corresponding MCP workloads. Terraform Stacks requires the original module
# source and provider mapping to destroy component instances safely.
removed {
  source = "./modules/workload-identity"
  from   = component.workload_identity_mcp_terraform

  providers = {
    google = provider.google.this
  }
}

removed {
  source = "./modules/workload-identity"
  from   = component.workload_identity_mcp_whatsapp

  providers = {
    google = provider.google.this
  }
}

removed {
  source = "./modules/workload-identity"
  from   = component.workload_identity_mcp_whatsapp_personal

  providers = {
    google = provider.google.this
  }
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

component "workload_identity_agents" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    # Preserve the existing GSA resource name while narrowing its only KSA
    # binding to the side-effecting activity worker.
    account_id   = "agent-platform"
    display_name = "AI agent activity worker identity"
    namespace    = local.ns["agents-activity"].namespace
    ksa_name     = local.ns["agents-activity"].ksa
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_backend_control_api" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "backend-control-api"
    display_name = "YourOwn.Chat backend control API identity"
    namespace    = local.ns["backend-control-api"].namespace
    ksa_name     = local.ns["backend-control-api"].ksa
    primary_ksa_binding_enabled = false
    additional_ksa_bindings = [{
      namespace = "server-control"
      ksa_name  = "control"
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_identity_api" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "yourown-chat-identity"
    display_name = "YourOwn.Chat identity API workload identity"
    namespace    = local.ns["identity-api"].namespace
    ksa_name     = local.ns["identity-api"].ksa
    primary_ksa_binding_enabled = false
    additional_ksa_bindings = [{
      namespace = "server-identity"
      ksa_name  = "api"
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_auth_api" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "yourown-chat-auth"
    display_name = "YourOwn.Chat public authorization API workload identity"
    namespace    = local.ns["auth-api"].namespace
    ksa_name     = local.ns["auth-api"].ksa
    primary_ksa_binding_enabled = false
    additional_ksa_bindings = [{
      namespace = "server-edge"
      ksa_name  = "auth"
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_transport_api" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "yourown-chat-transport"
    display_name = "YourOwn.Chat encrypted transport workload identity"
    namespace    = local.ns["transport-api"].namespace
    ksa_name     = local.ns["transport-api"].ksa
    primary_ksa_binding_enabled = false
    additional_ksa_bindings = [{
      namespace = "server-edge"
      ksa_name  = "transport"
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_identity_admin" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "yourown-chat-identity-admin"
    display_name = "YourOwn.Chat internal identity administration workload"
    namespace    = local.ns["identity-admin"].namespace
    ksa_name     = local.ns["identity-admin"].ksa
    primary_ksa_binding_enabled = false
    additional_ksa_bindings = [{
      namespace = "server-identity"
      ksa_name  = "admin"
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_identity_migrate" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "yourown-chat-migrate"
    display_name = "YourOwn.Chat identity database migration workload identity"
    namespace    = local.ns["identity-migrate"].namespace
    ksa_name     = local.ns["identity-migrate"].ksa
    primary_ksa_binding_enabled = false
    additional_ksa_bindings = [{
      namespace = "server-identity"
      ksa_name  = "migrate"
    }]
  }

  providers  = { google = provider.google.this }
  depends_on = [component.gke]
}

component "workload_identity_agent_workflow" {
  source = "./modules/workload-identity"

  inputs = {
    project_id   = component.project_services.project_id
    account_id   = "agent-workflow-worker"
    display_name = "AI agent deterministic workflow worker identity"
    namespace    = local.ns["agents-workflow"].namespace
    ksa_name     = local.ns["agents-workflow"].ksa
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
    calls_static_ip   = var.mattermost_calls_enabled
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

# One-time first-user credential. The password is generated ephemerally and
# written only to CMEK-protected Secret Manager. Only the migration workload
# can read it, and its idempotent bootstrap never replaces existing credentials.
component "identity_bootstrap_user_secret" {
  source = "./modules/bootstrap-user-secret"

  inputs = {
    project_id       = component.project_services.project_id
    location         = var.region
    secret_id        = "yourown-chat-pilprod-initial-password"
    kms_key_name     = one([for k in component.kms : k.crypto_key_id])
    labels           = local.common_labels
    accessor_members = [component.workload_identity_identity_migrate.iam_member]
    password_version = 1
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

removed {
  from   = component.keycloak_bootstrap_user_secret
  source = "./modules/bootstrap-user-secret"
  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

removed {
  from   = component.keycloak_native_auth_client_secret
  source = "./modules/bootstrap-user-secret"
  providers = {
    google = provider.google.this
    random = provider.random.this
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

    additional_buckets = var.temporal_enabled ? {
      agent-results = {
        name           = "agent-results-${var.project_id}-${var.region}"
        retention_days = var.agent_results_retention_days
        force_destroy  = false
        members        = [component.workload_identity_agents.iam_member]
      }
    } : {}
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
    # Pilot diagnostics: retain container stderr/stdout so authentication
    # failures are observable without granting interactive cluster access.
    # Cloud Logging exclusions can narrow this after the verification flow is
    # stable; the current pilot has only a small bounded workload set.
    logging_components         = ["SYSTEM_COMPONENTS", "WORKLOADS"]
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

# Data-only cluster authentication shared by the platform-owned official Helm
# services. It creates no GKE resources and uses the same keyless apply SA.
component "gke_auth" {
  source = "./modules/gke-auth"

  inputs = {
    gke_cluster_id = component.gke.cluster_id
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

    additional_database_users = merge(
      {
        yourown_chat_identity = {
          database_names              = ["yourown_chat_identity"]
          password_secret_id          = "yourown-chat-identity-db-password"
          password_secret_accessors   = []
          connection_secret_id        = "yourown-chat-identity-database-url"
          connection_secret_accessors = [
            component.workload_identity_identity_migrate.iam_member,
          ]
          password_rotation = var.yourown_chat_identity_password_rotation
        }
        yourown_chat_identity_runtime = {
          database_names            = ["yourown_chat_identity"]
          manage_databases          = false
          password_secret_id        = "yourown-chat-identity-runtime-db-password"
          password_secret_accessors = []
          connection_secret_id      = "yourown-chat-identity-runtime-database-url"
          connection_secret_accessors = [
            component.workload_identity_auth_api.iam_member,
            component.workload_identity_transport_api.iam_member,
            component.workload_identity_identity_api.iam_member,
            component.workload_identity_identity_admin.iam_member,
          ]
          password_rotation = var.yourown_chat_identity_password_rotation
        }
      },
      var.temporal_enabled ? {
        temporal = {
          database_names            = ["temporal", "temporal_visibility"]
          password_secret_id        = "temporal-db-password"
          password_secret_accessors = []
          password_rotation         = var.temporal_password_rotation
        }
      } : {},
      # Retained for one cutover stage. The runtime is no longer exposed to
      # clients and is removed only after native authentication is verified.
      var.keycloak_enabled ? {
        keycloak = {
          database_names            = ["keycloak"]
          password_secret_id        = "keycloak-db-password"
          password_secret_accessors = []
          password_rotation         = var.keycloak_password_rotation
        }
      } : {},
    )

    user_labels = local.common_labels
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# Temporal is an official platform service. Its GCP persistence is composed
# through the existing Cloud SQL and storage owners above; this module owns only
# the in-cluster namespace, policy, secret and pinned official Helm release.
component "temporal" {
  source = "./modules/temporal"

  inputs = {
    enabled             = var.temporal_enabled
    cloudsql_private_ip = one([for database in component.cloudsql : database.private_ip_address])
    cluster_dns_ip      = cidrhost(component.network.services_cidr, 10)
    database_password   = try(one([for database in component.cloudsql : database.additional_passwords["temporal"]]), "")
    chart_version       = var.temporal_chart_version
    labels              = local.common_labels
  }

  providers = {
    helm       = provider.helm.this
    kubernetes = provider.kubernetes.this
  }

  depends_on = [component.cloudsql, component.storage]
}

# Temporary cutover compatibility runtime. No application ingress or client
# contract points at this component. A follow-up removal is applied only after
# the native server release and bootstrap migration have been verified.
component "keycloak" {
  source = "./modules/keycloak"

  inputs = {
    enabled                  = var.keycloak_enabled
    project_id               = component.project_services.project_id
    region                   = var.region
    encryption_key_name      = one([for k in component.kms : k.crypto_key_id])
    cloudsql_private_ip      = one([for database in component.cloudsql : database.private_ip_address])
    cluster_dns_ip           = cidrhost(component.network.services_cidr, 10)
    database_password        = try(one([for database in component.cloudsql : database.additional_passwords["keycloak"]]), "")
    image_version            = var.keycloak_version
    public_url               = var.keycloak_public_url
    labels                   = local.common_labels
  }

  providers = {
    google     = provider.google.this
    random     = provider.random.this
    kubernetes = provider.kubernetes.this
  }

  depends_on = [component.cloudsql]
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
