# ---------------------------------------------------------------------------
# Unified component wiring. Each component is a logical building block backed by
# a reusable module under ./modules. Dependencies are expressed by referencing
# another component's outputs, which keeps ordering explicit and coupling loose.
#
# Graph:
#   project_services  (enables ALL APIs this product needs, in one place)
#     ├── network ── cloudsql ─┐
#     │        │  └── gke ── clouddeploy
#     │        └── cloudflare (edge; apex A -> network.ingress_ip_address)
#     │                 └── origin CA cert ─┐
#     ├── storage ──────────────────────────┤ (accessors)
#     ├── workload_identity_{mattermost,matterbridge,dev} ┤
#     ├── kms ───────────────────────────────┤ (CMEK)
#     ├── secrets  (origin TLS cert/key filled from cloudflare) ┘
#     ├── artifact_registry
#     └── mattermost_image (Cloud Build 2nd-gen CI -> artifact_registry)
#
# Consolidation: the GCP platform, the image-build CI and the Cloudflare edge
# used to be three separate stacks with manual hand-offs between them. They are
# now ONE stack. Two hand-offs disappear entirely:
#   - the reserved ingress IP is wired LIVE into the Cloudflare apex A record
#     (component.network.ingress_ip_address), so there is no copy-paste of the IP;
#   - the Cloudflare Origin CA cert/key flow straight into the platform
#     mattermost-origin-tls-* secrets, so there is no manual `gcloud secrets`.
#
# API enablement: one small BOOTSTRAP set (auth + serviceusage + secretmanager)
# is enabled once by hand in README.md (Terraform needs those before it can
# authenticate and enable anything else). This stack's project_services then
# enables everything else -- platform + build APIs together, no partitioning.
#
# Workload Identity SAs are created first (they only need the APIs enabled) and
# their IAM member strings are passed as least-privilege secretAccessors to the
# secret-owning components (cloudsql, storage, secrets). Every credential lives
# in Secret Manager, readable only by the exact workload.
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
    stack       = "yourown-chat"
  }, var.extra_labels)

  # ALL APIs the product needs, enabled in ONE place. The bootstrap set
  # (cloudresourcemanager, iam, iamcredentials, serviceusage, sts,
  # secretmanager) is enabled by hand in README.md before Terraform runs.
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
    "artifactregistry.googleapis.com",
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
component "kms" {
  for_each = var.cmek_enabled ? toset(["default"]) : toset([])

  source = "./modules/kms"

  inputs = {
    project_id = component.project_services.project_id
    # Regional name (europe-west3-keyring); the project prefix is dropped since
    # the project is already yourown-chat. Shared by Cloud SQL, GCS and Secret
    # Manager, all in the one region.
    location         = var.region
    protection_level = var.kms_protection_level
    rotation_period  = var.kms_rotation_period
    labels           = local.common_labels

    # The public registry is not CMEK-encrypted, so the Artifact Registry
    # service agent never wraps a DEK with this key.
    grant_artifact_registry = false
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
    network_id                    = component.network.network_id
    private_service_connection_id = component.network.private_service_connection_id
    tier                          = var.cloudsql_tier
    availability_type             = var.cloudsql_availability_type
    disk_size_gb                  = var.cloudsql_disk_size_gb
    deletion_protection           = var.cloudsql_deletion_protection

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

    user_labels = local.common_labels
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Continuous delivery ----------------------------------------------------
# Cloud Deploy governs promotion of the Kubernetes workloads (helm/) as a
# managed dev -> prod pipeline: two targets on the ONE cluster, each rendering a
# Skaffold profile from helm/skaffold.yaml. The Mattermost image is built once
# by the mattermost_image component (below) and promoted by tag.
component "clouddeploy" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = component.project_services.project_id
    region         = var.region
    gke_cluster_id = component.gke.cluster_id

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

# --- Additional application secrets (all credentials live in Secret Manager) -
component "secrets" {
  source = "./modules/secrets"

  inputs = {
    project_id        = component.project_services.project_id
    replica_locations = [var.region]
    labels            = local.common_labels

    # CMEK: shared key encrypts every secret replica (null when cmek_enabled =
    # false, i.e. the kms component is absent).
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
      # The origin TLS cert/key are populated LIVE from the cloudflare component
      # (Origin CA cert), so ingress-nginx can serve Full (Strict) TLS with zero
      # manual steps. When cloudflare_manage_origin_cert = false the values are
      # null and the module creates empty containers to be filled out-of-band.
      # The AOP CA stays an empty container (Cloudflare-supplied, not issued here).
      var.public_ingress_enabled ? {
        "mattermost-origin-tls-cert" = {
          value     = one([for c in component.cloudflare : c.origin_certificate_pem])
          accessors = [component.workload_identity_mattermost.iam_member]
        }
        "mattermost-origin-tls-key" = {
          value     = one([for c in component.cloudflare : c.origin_private_key_pem])
          accessors = [component.workload_identity_mattermost.iam_member]
        }
        "cloudflare-origin-pull-ca" = {
          # Explicit null (empty container) so all three entries share one object
          # type -> the conditional's branches unify as map(object) against {}.
          value     = null
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

# --- Unified container registry (one repo for all environments) -------------
component "artifact_registry" {
  source = "./modules/artifact-registry"

  inputs = {
    project_id    = component.project_services.project_id
    location      = var.region
    repository_id = var.artifact_registry_repository_id
    description   = "Unified container images (Mattermost + future services), promoted by tag across environments."
    kms_key_name  = var.artifact_registry_kms_key_name
    labels        = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# --- Mattermost image CI (Cloud Build 2nd-gen) ------------------------------
# Links the source repo (pilprod/mattermost) to the shared, out-of-band GitHub
# connection (console OAuth), plus one least-privilege build SA (repo-scoped
# writer on the registry above) and a tag-triggered build that pushes ONE image
# on a single tag pattern (^v.*-patched$), promoted dev -> prod by Cloud Deploy.
component "mattermost_image" {
  source = "./modules/cloudbuild-image"

  inputs = {
    project_id = component.project_services.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    # Existing, out-of-band Cloud Build connection (console OAuth) shared by the
    # image and deploy repos; Terraform only links repositories/triggers to it.
    connection_name   = var.github_connection_name
    github_remote_uri = var.github_remote_uri

    # Push every build to the ONE unified repository created above.
    artifact_registry_location      = component.artifact_registry.location
    artifact_registry_repository_id = component.artifact_registry.repository_id

    image_name = var.image_name
    builds     = var.builds
  }

  providers = {
    google = provider.google.this
    # Transitional: reconciles the pre-#30 beta service-agent still in state so
    # this apply can destroy it. Remove once the plan shows no beta resources.
    google-beta = provider.google-beta.this
  }
}

# --- Automated release cutting (Cloud Build 2nd-gen on git tags) -------------
# Makes deployment hands-off: links the DEPLOY repo (this one, holds helm/) to the
# shared out-of-band GitHub connection, plus a least-privilege releaser SA and a
# tag trigger. On a semver tag (release_tag_regex, i.e. *.*.*) it runs `gcloud
# deploy releases create` against the clouddeploy pipeline, so a tag — not a human
# — cuts the release. The releaser can create releases on that pipeline only and
# actAs the execution SA; it never touches the image build. Ordered AFTER kms so
# the source-staging bucket is CMEK-ready.
component "deploy_release" {
  source = "./modules/deploy-release"

  inputs = {
    project_id = component.project_services.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    # Same shared, out-of-band Cloud Build connection as the image CI (both repos
    # live under the pilprod account it authorizes).
    connection_name   = var.github_connection_name
    github_remote_uri = var.github_deploy_remote_uri

    # Cut releases against the pipeline the clouddeploy component owns.
    delivery_pipeline_name          = component.clouddeploy.delivery_pipeline_name
    execution_service_account_email = component.clouddeploy.execution_service_account_email

    release_tag_regex = var.release_tag_regex

    # CMEK the private source-staging bucket with the shared stack key (null when
    # cmek_enabled = false), mirroring the other data buckets.
    source_bucket_kms_key_name = one([for k in component.kms : k.crypto_key_id])

    labels = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# --- Cloudflare edge (public ingress only) ----------------------------------
# Drives the whole zone: DNS (proxied apex A wired LIVE to the platform ingress
# IP, www, extra records, CAA), edge TLS/security settings, DNSSEC, WAF rules and
# optional origin TLS (Origin CA cert + Authenticated Origin Pulls). Gated on
# public_ingress_enabled so dev/private deployments skip Cloudflare entirely.
component "cloudflare" {
  for_each = var.public_ingress_enabled ? toset(["default"]) : toset([])

  source = "./modules/cloudflare"

  inputs = {
    domain = var.domain
    # LIVE wiring: no manual IP hand-off. The reserved static IP the network
    # component allocates is the address the proxied apex A record points at.
    origin_ip     = component.network.ingress_ip_address
    proxied       = var.cloudflare_proxied
    manage_www    = var.cloudflare_manage_www
    extra_records = var.cloudflare_extra_records
    caa_records   = var.cloudflare_caa_records

    ssl_mode         = var.cloudflare_ssl_mode
    always_use_https = var.cloudflare_always_use_https
    min_tls_version  = var.cloudflare_min_tls_version
    hsts             = var.cloudflare_hsts
    dnssec_enabled   = var.cloudflare_dnssec_enabled

    custom_firewall_rules = var.cloudflare_custom_firewall_rules
    managed_waf_enabled   = var.cloudflare_managed_waf_enabled
    rate_limit_rules      = var.cloudflare_rate_limit_rules

    manage_origin_cert = var.cloudflare_manage_origin_cert
    aop_enabled        = var.cloudflare_aop_enabled
    aop_certificate    = var.cloudflare_aop_certificate
    aop_private_key    = var.cloudflare_aop_private_key
  }

  providers = {
    cloudflare = provider.cloudflare.this
    tls        = provider.tls.this
  }

  # Run Cloudflare as LATE as possible: it is the public edge and its Origin CA
  # cert/key feed the `secrets` component (mattermost-origin-tls-*), so it must
  # finish just BEFORE `secrets` — it cannot be strictly last. Waiting on all the
  # GCP infra here means a Cloudflare token/edge failure can't half-provision the
  # platform, and DNS only flips once everything it fronts already exists. We
  # depend on every component EXCEPT `secrets` (that would be a cycle) and self.
  depends_on = [
    component.project_services,
    component.network,
    component.kms,
    component.storage,
    component.gke,
    component.cloudsql,
    component.clouddeploy,
    component.artifact_registry,
    component.mattermost_image,
    component.deploy_release,
    component.workload_identity_mattermost,
    component.workload_identity_matterbridge,
    component.workload_identity_dev,
  ]
}
