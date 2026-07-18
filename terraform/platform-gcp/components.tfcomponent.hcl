# ---------------------------------------------------------------------------
# PLATFORM stack: the long-lived, stateful foundation. Everything here is slow
# to (re)create and expensive to lose: enabled APIs, the VPC, the CMEK key, the
# GKE cluster, the managed Postgres, the object-storage bucket, the container
# registry and the Workload Identity SAs.
#
# The fast-moving delivery layer (secrets, Cloud Deploy, image CI, release
# cutting, Cloudflare edge) lives in the sibling APP-GCP and CLOUDFLARE stacks, which
# consumes this stack's published outputs as a LINKED STACK (upstream_input).
# The contract is the publish_output blocks in platform.tfdeploy.hcl: the app
# stack only ever sees last-applied values, so the platform always settles
# first and an app-side mistake can never touch platform state.
#
# Graph (this stack):
#   project_services  (enables ALL APIs the product needs, in one place)
#     ├── network ── cloudsql
#     │        └── gke ── workload_identity_{mattermost,matterbridge,dev}
#     ├── kms ── {storage, cloudsql}   (CMEK)
#     ├── storage
#     └── artifact_registry
#
# Workload Identity SAs are platform (not app) on purpose: their iam_member
# strings gate access to the platform-owned secrets (cloudsql connection,
# storage HMAC keys) AND to the app-owned ones — keeping them here makes every
# cross-stack edge point the same way (app -> platform), so the graph stays
# acyclic.
# ---------------------------------------------------------------------------

locals {
  # Workload Identity service accounts are named by ROLE (mattermost = prod
  # Mattermost, mattermost-dev = dev copy, matterbridge = bridge), not by project:
  # the project is already yourown-chat, so a yourown-chat-* prefix would just
  # repeat it. Every other resource is named regionally (europe-west3-*).
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
    stack       = "yourown-chat-platform-gcp"
  }, var.extra_labels)

  # ALL APIs the product needs (platform AND app), enabled in ONE place: the app
  # stack owns no project_services so the two stacks can never fight over the
  # same google_project_service resources. The bootstrap set
  # (cloudresourcemanager, iam, iamcredentials, serviceusage, sts,
  # secretmanager) is enabled by hand in README.md before Terraform runs.
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
    # Artifact Analysis (vulnerability scanning) is a paid opt-in: the API is
    # only enabled when the registry actually scans, so a default deployment
    # carries no scanning surface (or cost) at all.
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

# --- Workload Identity service accounts (per tenant) ------------------------
component "workload_identity_mattermost" {
  source = "./modules/workload-identity"

  inputs = {
    project_id = component.project_services.project_id
    # Named by role: the prod Mattermost is the product, so its identity is
    # `mattermost`; the dev copy is `mattermost-dev`, the bridge `matterbridge`.
    account_id   = "mattermost"
    display_name = "Mattermost (prod) workload identity"
    namespace    = local.ns.mattermost.namespace
    ksa_name     = local.ns.mattermost.ksa
  }

  providers = {
    google = provider.google.this
  }

  # The workloadIdentityUser binding member references PROJECT.svc.id.goog, the
  # fixed Workload Identity pool that only comes into existence once a
  # WI-enabled GKE cluster is created. Without this ordering a fresh apply races
  # the cluster and 400s with "Identity Pool does not exist".
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

  # Needs the PROJECT.svc.id.goog pool created by the GKE cluster (see
  # workload_identity_mattermost).
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

  # Needs the PROJECT.svc.id.goog pool created by the GKE cluster (see
  # workload_identity_mattermost).
  depends_on = [component.gke]
}

# --- Networking -------------------------------------------------------------
component "network" {
  source = "./modules/network"

  inputs = {
    project_id = component.project_services.project_id
    region     = var.region
    labels     = local.common_labels

    # Reserve the Cloudflare-facing static IP only where a public ingress exists.
    # The cloudflare stack's apex A record consumes it via upstream_input.
    ingress_static_ip = var.public_ingress_enabled
  }

  providers = {
    google = provider.google.this
  }
}

# --- Shared CMEK key (Cloud SQL + GCS + Secret Manager) ---------------------
# One customer-managed Cloud KMS key wraps the data-encryption keys of every
# at-rest store that supports CMEK. Gated by cmek_enabled; when false the
# component is skipped and each store falls back to Google-managed keys. The
# PUBLIC Artifact Registry does NOT use CMEK, so the service agent is not granted.
# The app-gcp stack's secrets + release-source bucket reuse this key via
# upstream_input (cmek_key_id).
component "kms" {
  for_each = var.cmek_enabled ? toset(["default"]) : toset([])

  source = "./modules/kms"

  inputs = {
    project_id = component.project_services.project_id
    # Regional name (europe-west3); the project prefix is dropped since the
    # project is already yourown-chat. Shared by Cloud SQL, GCS and Secret
    # Manager, all in the one region.
    location         = var.region
    protection_level = var.kms_protection_level
    rotation_period  = var.kms_rotation_period
    labels           = local.common_labels

    # KMS objects are never deletable in GCP: adopt the pre-existing ring/key
    # when re-bootstrapping this project (see kms_adopt_existing).
    adopt_existing = var.kms_adopt_existing

    # The public registry is not CMEK-encrypted, so the Artifact Registry
    # service agent never wraps a DEK with this key.
    grant_artifact_registry = false

    # Let the GKE service agent use this key for application-layer Secrets
    # encryption of etcd (the gke component's database_encryption_key below).
    grant_gke      = true
    project_number = var.project_number
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
    location      = upper(var.region)
    force_destroy = var.storage_force_destroy
    labels        = local.common_labels

    # CMEK: shared key (null when cmek_enabled = false).
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

    # Application-layer Secrets encryption (etcd) with the shared CMEK key. Null
    # when cmek_enabled = false (component.kms is empty), which omits the block
    # -> Google-managed at-rest only. Referencing the kms output makes gke wait
    # for the key AND its GKE-agent encrypterDecrypter grant (grant_gke above).
    database_encryption_key = one([for k in component.kms : k.crypto_key_id])
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
    region                        = var.region
    zone                          = var.zone
    network_id                    = component.network.network_id
    private_service_connection_id = component.network.private_service_connection_id
    tier                          = var.cloudsql_tier
    availability_type             = var.cloudsql_availability_type
    disk_size_gb                  = var.cloudsql_disk_size_gb
    deletion_protection           = var.cloudsql_deletion_protection
    adopt_existing_instance       = var.cloudsql_adopt_existing_instance

    # CMEK: shared key (null when cmek_enabled = false). The key's
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

    # Deliberate password rotation: bump cloudsql_password_rotation to rotate.
    password_rotation = var.cloudsql_password_rotation

    user_labels = local.common_labels
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Unified container registry (one repo for all environments) -------------
# Platform, not app: the repository is a stateful store of released images —
# losing it would orphan every promoted tag. The app-gcp stack's image CI pushes to
# it via upstream_input (artifact_registry_location / _repository_id).
component "artifact_registry" {
  source = "./modules/artifact-registry"

  inputs = {
    project_id    = component.project_services.project_id
    location      = var.region
    repository_id = var.artifact_registry_repository_id
    description   = "Unified container images (Mattermost + future services), promoted by tag across environments."
    kms_key_name  = var.artifact_registry_kms_key_name
    labels        = local.common_labels

    # Scan pushed images for vulnerabilities (paid; API gated in activate_apis).
    vulnerability_scanning = var.artifact_registry_vulnerability_scanning
  }

  providers = {
    google = provider.google.this
  }
}
