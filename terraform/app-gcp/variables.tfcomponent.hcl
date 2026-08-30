# ---------------------------------------------------------------------------
# APP-GCP stack inputs. Values are supplied by app.tfdeploy.hcl. The upstream-owned
# values (cluster ID, registry coordinates, CMEK key, Workload Identity
# members) arrive there as upstream_input from the
# LINKED platform-gcp stack -- declared here as ordinary variables, so the components stay
# testable and the linkage is confined to the deployment file.
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID for this environment."
}

variable "environment" {
  type        = string
  description = "Environment name (drives labels only)."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be dev, stage or prod."
  }
}

variable "region" {
  type        = string
  description = "Primary region. europe-west3 = Frankfurt, Germany. Also the Cloud Build / Cloud Deploy region."
  default     = "europe-west3"
}

variable "apple_association_app_id" {
  type        = string
  description = "Public Apple application identifier allowed to use passkeys for yourown.chat."

  validation {
    condition     = length(var.apple_association_app_id) >= 3 && length(var.apple_association_app_id) <= 255 && !strcontains(var.apple_association_app_id, " ")
    error_message = "apple_association_app_id must be a valid public Apple application identifier."
  }
}

# --- Keyless auth: HCP Dynamic Provider Credentials -> GCP WIF ---------------
variable "identity_token" {
  type        = string
  ephemeral   = true
  description = "HCP Terraform OIDC JWT, minted per run. Ephemeral: never persisted to stack state."
}

variable "audience" {
  type        = string
  description = "STS audience = full WIF provider resource name (//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL_ID>/providers/<PROVIDER_ID>)."
}

variable "service_account_email" {
  type        = string
  description = "Least-privilege GCP apply SA impersonated by Terraform via WIF (never Owner/Editor). Also granted actAs on the build SA so it can create triggers that run as that identity."
}

# --- Values published by the LINKED platform-gcp stack -----------------------
variable "gke_cluster_id" {
  type        = string
  description = "Full GKE cluster resource ID (projects/<p>/locations/<l>/clusters/<n>) shared by every Cloud Deploy target. Published by the platform stack (upstream_input.platform.gke_cluster_id)."
}

variable "agentgateway_platform" {
  type = object({
    enabled                    = bool
    namespace                  = string
    gateway_api_version        = string
    gateway_class_name         = string
    controller_name            = string
    chart_version              = string
    service_account_name       = string
    read_cluster_role_name     = string
    deployer_cluster_role_name = string
  })
  description = "Official agentgateway control-plane contract published by platform-gcp."
  default = {
    enabled                    = false
    namespace                  = "agentgateway-system"
    gateway_api_version        = "v1.6.0"
    gateway_class_name         = "agentgateway"
    controller_name            = "agentgateway.dev/agentgateway"
    chart_version              = "v1.5.0"
    service_account_name       = "agentgateway"
    read_cluster_role_name     = "agentgateway-agentgateway-system"
    deployer_cluster_role_name = "agentgateway-agentgateway-system-deployer"
  }
}

variable "agentgateway_public_ip_address" {
  type        = string
  description = "Dedicated regional public address for the application-owned production-ineligible testbed Gateway."
  default     = null
}

variable "agentgateway_public_ip_name" {
  type        = string
  description = "GCP address resource name used by the GKE L4 RBS annotation."
  default     = null
}

variable "artifact_registry_location" {
  type        = string
  description = "Artifact Registry location the image CI pushes to. Published by the platform stack."
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Artifact Registry repository ID the image CI pushes to. Published by the platform stack."
}

variable "cmek_key_id" {
  type        = string
  description = "Shared CMEK key resource ID encrypting this stack's secrets and the release-source bucket (null when the platform runs cmek_enabled = false). Published by the platform stack."
  default     = null
}

variable "workload_identity_members" {
  type        = map(string)
  description = "Tenant (mattermost/matterbridge/dev) => IAM member string (serviceAccount:<email>) used as least-privilege secretAccessor grants. Published by the platform stack."
}

variable "helm_registry_repository_id" {
  type        = string
  description = "Artifact Registry repository ID of the platform Helm workload-profile charts (published by the platform-gcp stack as helm_registry_repository_id). null until platform-gcp has been applied with that repository; wrapper releases require it and the chart publication rail publishes into it."
  default     = null
}

# --- Wrapper-based delivery (platform workload profiles) -----------------------
variable "wrapper_releases_enabled" {
  type        = bool
  description = "Cut service releases from the service repository's helm/release.yaml and platform-profile release wrappers (rendered through helm/platform/release/assemble.sh) instead of the legacy charts under helm/. Requires helm_registry_repository_id. Default false keeps the legacy release path unchanged."
  default     = false
}

# --- Image-build CI (Cloud Build 2nd-gen) ------------------------------------
# Repository connections are service-owned inputs declared alongside the
# app-gcp deployment. Credentials are not stored in these values.
variable "github_connection_name" {
  type        = string
  description = "Name of the EXISTING Cloud Build 2nd-gen GitHub connection, authorized once in the console via OAuth (see README.md). Every source repository is linked to it by ID; Terraform never creates or manages the connection."
}

variable "source_repositories" {
  type = map(object({
    name       = string
    remote_uri = string
  }))
  description = "Source repositories keyed by role. Required roles: deploy (this platform repository, the Skaffold render root), mattermost (product assembly), web, server_source (patched server source, provenance only), backend, agents, mcp, rtcd. `name` is the Cloud Build 2nd-gen repository resource name; `remote_uri` is the HTTPS clone URL."
}

variable "vendor_chart_bundles" {
  type = map(object({
    provisioned              = bool
    application_enabled      = bool
    deployment_class         = string
    production_eligible      = bool
    candidate_tag            = string
    product_commit           = string
    source_commit            = string
    supported_agent_runtimes = set(string)
    image_digests            = map(string)
    charts = object({
      crds = object({
        release_name  = string
        ref           = string
        version       = string
        values_path   = string
        values_sha256 = string
      })
      application = object({
        release_name  = string
        ref           = string
        version       = string
        values_path   = string
        values_sha256 = string
      })
    })
    namespaces = map(object({
      name          = string
      quota_profile = string
    }))
    endpoints = map(object({
      namespace_key = string
      pod_selector  = map(string)
    }))
    external_sources = map(object({
      namespace    = string
      pod_selector = map(string)
    }))
    flows = map(object({
      source_kind     = string
      source_key      = string
      destination_key = string
      ports = set(object({
        port     = number
        protocol = string
      }))
    }))
    kubernetes_api_egress_from = set(string)
    database_bindings = map(object({
      source_endpoint_key   = string
      secret_id_key         = string
      secret_provider_class = string
      secret_file           = string
      port                  = number
    }))
  }))
  description = "Service-owned vendor OCI chart bundles consumed by the reusable adapter."
  default     = {}
}

variable "kagent_substrate_delivery" {
  type = object({
    bootstrap_enabled                  = optional(bool, false)
    release_enabled                    = optional(bool, false)
    production_eligible                = optional(bool, false)
    native_secret_sync_ready           = optional(bool, false)
    crd_ownership_ready                = optional(bool, false)
    controller_namespace_handoff_ready = optional(bool, false)
    external_broker_smoke_ready        = optional(bool, false)
    artifacts = optional(map(object({
      source_repository        = string
      source_commit            = string
      artifact_manifest_sha256 = string
      artifact_schema_version  = string
      charts = object({
        application = object({
          ref     = string
          version = string
        })
        crds = object({
          ref     = string
          version = string
        })
      })
      image_refs = map(string)
    })), {})
    compatibility = optional(object({
      kagent_rbac_create_false            = bool
      kagent_obsolete_skills_init_removed = bool
      substrate_rbac_create_false         = bool
      substrate_gateway_api_v1            = bool
      substrate_go_module_commit          = string
      }), {
      kagent_rbac_create_false            = false
      kagent_obsolete_skills_init_removed = false
      substrate_rbac_create_false         = false
      substrate_gateway_api_v1            = false
      substrate_go_module_commit          = ""
    })
    helm_set_values     = optional(map(map(string)), {})
    values_sha256       = optional(map(string), {})
    kagent_health_url   = optional(string, "")
    substrate_endpoint  = optional(string, "")
    broker_server_name  = optional(string, "")
    broker_service_name = optional(string, "api")
    broker_service_port = optional(number, 8443)
    atenet_egress_destinations = optional(map(object({
      cidr = string
      port = number
    })), {})
  })
  description = "Fail-closed two-phase contract: bootstrap owns pre-sync infrastructure, while release admits the production-ineligible kagent/Substrate Helm workload only after native Secret synchronization."
  default     = {}

  validation {
    condition = !(
      var.kagent_substrate_delivery.bootstrap_enabled ||
      var.kagent_substrate_delivery.release_enabled
      ) || (
      !var.kagent_substrate_delivery.production_eligible &&
      toset(keys(var.kagent_substrate_delivery.artifacts)) == toset(["kagent", "substrate"]) &&
      var.kagent_substrate_delivery.artifacts["kagent"].source_repository == "https://github.com/pilprod/kagent" &&
      var.kagent_substrate_delivery.artifacts["substrate"].source_repository == "https://github.com/pilprod/substrate" &&
      alltrue([
        for artifact in values(var.kagent_substrate_delivery.artifacts) :
        can(regex("^[0-9a-f]{40}$", artifact.source_commit)) &&
        can(regex("^[0-9a-f]{64}$", artifact.artifact_manifest_sha256)) &&
        can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", artifact.artifact_schema_version)) &&
        alltrue([
          for chart in values(artifact.charts) :
          can(regex("^oci://[^@[:space:]]+@sha256:[0-9a-f]{64}$", chart.ref)) &&
          can(regex("^v?[0-9]+\\.[0-9]+\\.[0-9]+", chart.version))
        ]) &&
        length(artifact.image_refs) > 0 &&
        alltrue([
          for ref in values(artifact.image_refs) :
          can(regex("^[^@[:space:]]+/[^@[:space:]]+@sha256:[0-9a-f]{64}$", ref))
        ])
      ]) &&
      toset(keys(var.kagent_substrate_delivery.artifacts["kagent"].image_refs)) == toset(["controller", "ui", "agent"]) &&
      toset(keys(var.kagent_substrate_delivery.artifacts["substrate"].image_refs)) == toset(["ateapi", "atecontroller", "atenet", "agentgateway", "releaseVerifier"]) &&
      can(regex("^ghcr\\.io/pilprod/substrate/substrate-release-verify@sha256:[0-9a-f]{64}$", var.kagent_substrate_delivery.artifacts["substrate"].image_refs.releaseVerifier)) &&
      toset(keys(var.kagent_substrate_delivery.helm_set_values)) == toset(["kagent", "substrate"]) &&
      var.kagent_substrate_delivery.compatibility.kagent_rbac_create_false &&
      var.kagent_substrate_delivery.compatibility.kagent_obsolete_skills_init_removed &&
      var.kagent_substrate_delivery.compatibility.substrate_rbac_create_false &&
      var.kagent_substrate_delivery.compatibility.substrate_gateway_api_v1 &&
      var.kagent_substrate_delivery.compatibility.substrate_go_module_commit == var.kagent_substrate_delivery.artifacts["substrate"].source_commit &&
      var.kagent_substrate_delivery.kagent_health_url == "http://kagent-controller.kagent-system.svc.cluster.local:8083/health" &&
      can(regex("^api\\.ate-system\\.svc\\.cluster\\.local:[0-9]+$", var.kagent_substrate_delivery.substrate_endpoint)) &&
      can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.kagent_substrate_delivery.broker_server_name)) &&
      var.kagent_substrate_delivery.broker_service_port >= 1 &&
      var.kagent_substrate_delivery.broker_service_port <= 65535 &&
      length(var.kagent_substrate_delivery.atenet_egress_destinations) > 0 &&
      alltrue([
        for destination in values(var.kagent_substrate_delivery.atenet_egress_destinations) :
        can(cidrhost(destination.cidr, 0)) &&
        destination.cidr != "0.0.0.0/0" &&
        destination.cidr != "::/0" &&
        destination.port >= 1 &&
        destination.port <= 65535
      ])
    )
    error_message = "Enabled bootstrap or release requires separate pilprod/kagent and pilprod/substrate manifests, digest-qualified app+CRD charts/images, an exact Substrate dependency commit, RBAC/Gateway API capabilities, a verifier and testbed-only endpoints. External Broker smoke is a post-bootstrap local-agent-ready gate."
  }

  validation {
    condition = !(
      var.kagent_substrate_delivery.bootstrap_enabled ||
      var.kagent_substrate_delivery.release_enabled
      ) || (
      toset(keys(var.kagent_substrate_delivery.values_sha256)) == toset([
        "kagent/kagent.values.yaml",
        "kagent/kagent-testbed.values.yaml",
        "kagent/substrate.values.yaml",
        "kagent/substrate-testbed.values.yaml",
      ]) &&
      alltrue([for checksum in values(var.kagent_substrate_delivery.values_sha256) : can(regex("^[0-9a-f]{64}$", checksum))])
    )
    error_message = "Enabled testbed bootstrap or release must checksum exactly the four tracked kagent/Substrate values files."
  }

  validation {
    condition = !var.kagent_substrate_delivery.release_enabled || (
      var.kagent_substrate_delivery.bootstrap_enabled &&
      var.kagent_substrate_delivery.native_secret_sync_ready
    )
    error_message = "release_enabled requires bootstrap_enabled=true and native_secret_sync_ready=true; bootstrap resources must exist before the Helm workload is admitted."
  }
}

variable "additional_cloudsql_connection_secret_ids" {
  type        = map(string)
  description = "Platform-created additional database role => ready-to-use connection URI Secret Manager ID."
  default     = {}
}

variable "image_name" {
  type        = string
  description = "Image name (last path segment) pushed under the unified Artifact Registry repository."
  default     = "mattermost"
}

variable "builds" {
  type = map(object({
    branch_regex    = optional(string)
    tag_regex       = optional(string)
    delivery        = string
    release_channel = string
  }))
  description = "Mattermost assembly build entrypoints. Stable semver tags use the production flow; prerelease tags and version branches are preview-only."
  default = {
    mattermost = {
      tag_regex       = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
      delivery        = "production"
      release_channel = "production"
    }
    mattermost-prerelease = {
      tag_regex       = "^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9A-Za-z][0-9A-Za-z.-]*$"
      delivery        = "preview"
      release_channel = "prerelease"
    }
    mattermost-preview = {
      branch_regex    = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
      delivery        = "preview"
      release_channel = "experimental"
    }
  }
}

# --- Automated release cutting (Cloud Deploy on a git tag) ------------------
# The deploy, backend, agents, mcp and rtcd repository links come from
# var.source_repositories; see service-inputs.tfdeploy.hcl and components.
variable "mcp_release_tag_regex" {
  type        = string
  description = "Immutable MCP source tags that build, scan and release all owned MCP server images."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "backend_release_tag_regex" {
  type        = string
  description = "Immutable server tags that build the client-facing control API image."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "agents_release_tag_regex" {
  type        = string
  description = "Immutable agent tags that build the workflow and activity worker images."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

variable "release_tag_regex" {
  type        = string
  description = "Git tag regex (on the deploy repo) that triggers an automatic Cloud Deploy release cut. Defaults to semantic MAJOR.MINOR.PATCH — the *.*.* pattern (e.g. 1.2.3)."
  default     = "^[0-9]+\\.[0-9]+\\.[0-9]+$"
}

# --- Labels -----------------------------------------------------------------
variable "extra_labels" {
  type        = map(string)
  description = "Additional labels merged onto every labellable resource."
  default     = {}
}

variable "gcs_bucket_name" {
  type        = string
  description = "Mattermost object-storage bucket name. Published by the platform-gcp stack; rendered into the operator CR (spec.fileStore.external.bucket) via Cloud Deploy deploy parameters."
}

variable "cloudsql_private_ip" {
  type        = string
  description = "Exact private Cloud SQL address allowed by the production Mattermost NetworkPolicy."
}

variable "cluster_dns_ip" {
  type        = string
  description = "Exact kube-dns Service ClusterIP allowed by Dataplane V2 application policies."
}

variable "workload_identity_emails" {
  type        = map(string)
  description = "Tenant (mattermost/matterbridge/dev) => GSA email. Published by the platform-gcp stack; rendered into the KSA iam.gke.io/gcp-service-account annotations via Cloud Deploy deploy parameters."
}

# --- Cluster bootstrap (operator + ingress-nginx Helm releases) --------------
variable "ingress_ip_address" {
  type        = string
  description = "Reserved static ingress IP (the Cloudflare-facing 'white address'). Published by the platform-gcp stack; injected into the ingress-nginx values as loadBalancerIP. null skips the ingress-nginx release."
  default     = null
}

variable "calls_ip_address" {
  type        = string
  description = "Reserved external IPv4 address advertised by RTCD and assigned to its TCP/UDP LoadBalancer Services."
  default     = null
}

variable "mattermost_operator_chart_version" {
  type        = string
  description = "mattermost/mattermost-operator chart version (https://helm.mattermost.com). Pinned for reproducible bootstrap; bump deliberately."
}

variable "ingress_nginx_chart_version" {
  type        = string
  description = "ingress-nginx/ingress-nginx chart version (https://kubernetes.github.io/ingress-nginx). Pinned for reproducible bootstrap; bump deliberately."
}

variable "adopt_existing_cluster_bootstrap_releases" {
  type        = bool
  description = "Import pre-existing cluster bootstrap Helm releases (mattermost-operator and ingress-nginx) that were installed by an interrupted/previous apply but are not yet in Terraform state."
  default     = false
}

variable "manage_ingress_origin_tls" {
  type        = bool
  description = "Materialise the mattermost-origin-tls Kubernetes Secret (Cloudflare Origin CA cert/key, for the ingress Full (Strict) TLS) from the Secret Manager values the cloudflare stack writes. Set from the cloudflare stack's origin_secret_ids in the deployment; false skips it (no public ingress)."
  default     = false
}

variable "aop_enabled" {
  type        = bool
  description = "Authenticated Origin Pulls (per-hostname mTLS) enforcement for the ingress -- derived in the deployment from the cloudflare stack's published aop_enabled, not set by hand. Only toggles the ingress verify-client: the cloudflare-origin-pull-ca Kubernetes Secret is materialised whenever origin TLS is managed (its CA is self-generated by the cloudflare stack), so annotation parsing never fails. true = enforce client-cert verification; false = Full (Strict) TLS only (CA loaded but inert)."
  default     = false
}

variable "adopt_existing_namespaces" {
  type        = bool
  description = "Import the tenant namespaces (dev/matterbridge/mattermost) if they already exist in the cluster (e.g. created by a previous Cloud Deploy namespaces.yaml) instead of failing with 'already exists'. Set true for the one-time adoption apply, then back to false."
  default     = false
}

variable "matterbridge_enabled" {
  type        = bool
  description = "Deploy matterbridge (the isolated chat bridge) as part of the dev Cloud Deploy stage. true -> the 'matterbridge' Skaffold profile is appended to the dev target (SA + NetworkPolicy + SecretProviderClass + Deployment rendered) and its dedicated namespace is created; false -> the dev target renders only the shared dev services and databases, and the matterbridge namespace is removed. The matterbridge-tokens Secret Manager secret is kept either way (preserves an operator-supplied token across a toggle)."
  default     = true
}

variable "mcp_servers_enabled" {
  type        = bool
  description = "Enable the in-cluster MCP delivery path. true lets unified platform tags route helm/mcp changes through the mcp dev -> prod pipeline; false skips MCP releases. Vendor-hosted remote MCP endpoints are unaffected -- see docs/MCP.md."
  default     = false
}

variable "agent_platform_enabled" {
  type        = bool
  description = "Create the agent pilot delivery path and allow semver tags to route agent changes. Persistent storage is owned separately by platform-gcp."
  default     = false
}

variable "yourown_chat_server_enabled" {
  type        = bool
  description = "Create and deliver the independent client-facing YourOwn.Chat server plane."
  default     = true
}

variable "identity_bootstrap_user_password_secret_id" {
  type        = string
  description = "Platform-owned Secret Manager ID containing the temporary initial native-user password."
  default     = "yourown-chat-pilprod-initial-password"
}

variable "yourown_chat_identity_connection_secret_id" {
  type        = string
  description = "Platform-owned Secret Manager ID containing the identity migration database URI."
  default     = "yourown-chat-identity-database-url"
}

variable "yourown_chat_identity_runtime_connection_secret_id" {
  type        = string
  description = "Platform-owned Secret Manager ID containing the least-privilege identity runtime database URI."
  default     = "yourown-chat-identity-runtime-database-url"
}

variable "yourown_chat_registration_enabled" {
  type        = bool
  description = "Pilot switch for public identity registration. Disable after the initial user cohort is created."
  default     = false
}

variable "temporal_enabled" {
  type        = bool
  description = "Explicit launch gate for Terraform-owned Temporal infrastructure. Keep false until the prerequisite MCP production release has passed verification."
  default     = false
}

variable "agent_results_bucket" {
  type        = string
  description = "Platform-owned result bucket passed to agent workload delivery. Empty while Temporal is disabled."
  default     = ""
}

variable "agent_platform_runtime_enabled" {
  type        = bool
  description = "Default semver release mode for the agent pilot. false routes the release through the static pause profile; true uses the static running profile. Both preserve Cloud SQL and GCS state."
  default     = false
}

variable "zero_trust_enabled" {
  type        = bool
  description = "Materialise the mcp-tunnel Kubernetes Secret (cloudflared run token, written to Secret Manager by the cloudflare stack's zero_trust component) so the tunnel pod in helm/mcp can start. MUST follow the cloudflare stack's zero_trust_enabled: enabling it here first would 404 on the missing Secret Manager secret. The chart-side switch is tunnel.enabled in helm/mcp/values.yaml."
  default     = false
}

variable "mcp_capability_sync_enabled" {
  type        = bool
  description = "Attach the Cloudflare AI Controls capability sync to verified production MCP rollouts. Enable in environments where the CMEK-encrypted sync credential exists so catalog and OAuth regressions fail visibly during delivery."
  default     = false
}

variable "dev_team_rbac_subjects" {
  type = list(object({
    kind = string
    name = string
  }))
  description = "Dev-team RBAC subjects granted edit rights in the `dev` namespace (Google Group or Users). Empty (default) creates no RBAC. Created by Terraform, NOT Cloud Deploy (whose execution SA cannot manage RBAC). A Group subject requires 'Google Groups for GKE RBAC' on the cluster."
  default     = []
}
