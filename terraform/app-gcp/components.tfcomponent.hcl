# ---------------------------------------------------------------------------
# APP-GCP stack: the fast-moving GCP delivery layer. Everything here is cheap
# to recreate and changes often: application secrets, the Cloud Deploy
# pipeline, the image-build CI and the tag-triggered release cutting.
#
# This stack is LINKED to platform-gcp (see app.tfdeploy.hcl): the stateful
# foundation (cluster ID, CMEK, registry coordinates, Workload Identity
# members) arrives as last-APPLIED upstream outputs, so the platform always
# settles first and a mistake here can never touch its state (separate state,
# separate blast radius). The Cloudflare edge and its origin-TLS secrets live
# in the sibling cloudflare stack.
#
# Graph (this stack; <upstream> = linked values passed in as plain vars):
#   clouddeploy (targets on <gke_cluster_id>) ── deploy_release
#   mattermost_image  -> pushes to <artifact_registry_*>
#   secrets (dev-postgres-password + matterbridge-tokens,
#            accessors = <workload_identity_members>)
#   gke_auth (lookup on <gke_cluster_id>) ─ helm provider ─ cluster_bootstrap
#            (mattermost-operator + ingress-nginx on <ingress_ip_address>)
# ---------------------------------------------------------------------------

locals {
  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-app-gcp"
  }, var.extra_labels)
}

# --- Continuous delivery ----------------------------------------------------
# Cloud Deploy governs promotion of the Kubernetes workloads (helm/) as a
# managed dev -> prod pipeline: two targets on the ONE platform cluster, each
# rendering a Skaffold profile from helm/skaffold.yaml. The Mattermost image is
# built once by the mattermost_image component (below) and promoted by tag.
component "clouddeploy" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id

    # matterbridge is an OPTIONAL second Skaffold profile appended to the dev
    # stage (see helm/skaffold.yaml). Toggle it with var.matterbridge_enabled:
    # true -> ["dev", "matterbridge"] (bridge deployed), false -> ["dev"] (not).
    stages = [
      {
        name             = "dev"
        profiles         = var.matterbridge_enabled ? ["dev", "matterbridge"] : ["dev"]
        require_approval = false
        verify           = true
      },
      { name = "prod", profiles = ["prod"], require_approval = true, verify = false },
    ]

    # In-cluster MCP servers (helm/mcp-servers) ride the prod stage as an extra
    # profile when enabled; per-server on/off lives in the chart's values.yaml.
    mcp_servers_enabled = var.mcp_servers_enabled

    # Rendered into the manifests' `# from-param: ${...}` placeholders on every
    # release, so the platform-published values (bucket, WI emails) flow from
    # Terraform into Kubernetes without hand-edited markers.
    deploy_parameters = {
      filestore_bucket   = var.gcs_bucket_name
      mattermost_gsa     = var.workload_identity_emails.mattermost
      mattermost_dev_gsa = var.workload_identity_emails.dev
      matterbridge_gsa   = var.workload_identity_emails.matterbridge
      # NOTE: credential values (dev Postgres password, DB connection string,
      # filestore HMAC keys) are deliberately NOT deploy parameters -- they would
      # land in the Cloud Deploy pipeline config and release renders. The
      # cluster_secrets component creates those Kubernetes Secrets directly in
      # etcd instead. Only non-secret wiring flows here.
      #
      # AOP toggle for the ingress (non-secret): "on" enforces client-cert mTLS
      # against cloudflare-origin-pull-ca, "off" is Full (Strict) TLS only.
      aop_verify_client = var.aop_enabled ? "on" : "off"
      # GSA behind the mcp-servers KSA (Workload Identity, keyless GCP reads
      # for the google-cloud MCP server). lookup(): the `mcp` key appears in
      # the platform-published map only after the platform stack applies the
      # workload_identity_mcp component -- empty until then, so this stack
      # still plans (the annotation just stays blank until platform is applied).
      mcp_gsa = lookup(var.workload_identity_emails, "mcp", "")
    }

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

# --- Additional application secrets (all credentials live in Secret Manager) -
component "secrets" {
  source = "./modules/secrets"

  inputs = {
    project_id        = var.project_id
    replica_locations = [var.region]
    labels            = local.common_labels

    # CMEK: the platform's shared key encrypts every secret replica (null when
    # the platform runs with cmek_enabled = false).
    kms_key_name = var.cmek_key_id

    secrets = {
      # In-cluster dev Postgres password (generated, read by the dev tenant).
      # special = false keeps it alphanumeric: dev Mattermost embeds it in a
      # postgres://mmuser:PW@dev-postgres/... DSN, where @ : / would corrupt the
      # URL. The value feeds the dev-postgres Kubernetes Secret via the
      # cluster_secrets component (created directly in etcd, not via Cloud
      # Deploy); the managed GKE add-on cannot sync secretObjects, so dev does
      # not use the CSI mount for it.
      "dev-postgres-password" = {
        generate  = true
        special   = false
        accessors = [var.workload_identity_members.dev]
      }
      # matterbridge bridge config. Seed a DEFAULT matterbridge.toml so a secret
      # version always exists and the pod leaves ContainerCreating on init (the
      # CSI mount needs >=1 version -- an empty secret would wedge the pod). The
      # default points at the IN-CLUSTER prod Mattermost Service on 8065
      # (matterbridge bridges in-cluster; the public yourown.chat path is closed
      # to it by Cloudflare + Authenticated Origin Pulls -- see
      # helm/matterbridge/networkpolicy.yaml). The gateway ships DISABLED with
      # placeholder creds, so matterbridge starts and idles without a failing
      # login. To go live, add a NEW version out-of-band with a real bot Token,
      # Team and enable=true (versions/latest is what the pod mounts):
      #   gcloud secrets versions add matterbridge-tokens --data-file=matterbridge.toml
      "matterbridge-tokens" = {
        value     = <<-TOML
          # Default seeded by Terraform so the matterbridge pod starts on init.
          # Replace Token/Team and set enable=true (add a new Secret Manager
          # version) to bridge the prod Mattermost.
          [mattermost.prod]
          Server="mattermost.mattermost.svc.cluster.local:8065"
          NoTLS=true
          Team="REPLACE_ME_TEAM"
          Token="REPLACE_ME_TOKEN"
          PrefixMessagesWithNick=true
          RemoteNickFormat="[{PROTOCOL}] <{NICK}> "

          [[gateway]]
          name="prod"
          enable=false

          [[gateway.inout]]
          account="mattermost.prod"
          channel="off-topic"
        TOML
        accessors = [var.workload_identity_members.matterbridge]
      }
      # Google Workspace OAuth client for the google-workspace MCP server.
      # Seeded with placeholders so the Kubernetes Secret always materialises
      # and the pod starts; load the REAL client id/secret out-of-band (add new
      # Secret Manager versions, see docs/MCP.md) and restart the pod:
      #   printf '%s' "<id>"     | gcloud secrets versions add mcp-google-workspace-client-id --data-file=-
      #   printf '%s' "<secret>" | gcloud secrets versions add mcp-google-workspace-client-secret --data-file=-
      # HCP Terraform API token for the terraform MCP server (workspaces/runs/
      # stacks on app.terraform.io). Seeded with a placeholder so the pod always
      # starts (registry tools work tokenless); load a real TEAM token scoped to
      # the yourown-chat HCP project out-of-band and restart:
      #   printf '%s' "<token>" | gcloud secrets versions add mcp-terraform-hcp-token --data-file=-
      "mcp-terraform-hcp-token" = {
        value     = "REPLACE_ME_HCP_TEAM_TOKEN"
        accessors = [for m in [lookup(var.workload_identity_members, "mcp", "")] : m if m != ""]
      }
      "mcp-google-workspace-client-id" = {
        value     = "REPLACE_ME_CLIENT_ID"
        accessors = [for m in [lookup(var.workload_identity_members, "mcp", "")] : m if m != ""]
      }
      "mcp-google-workspace-client-secret" = {
        value     = "REPLACE_ME_CLIENT_SECRET"
        accessors = [for m in [lookup(var.workload_identity_members, "mcp", "")] : m if m != ""]
      }
      # The Cloudflare origin-protection secrets (mattermost-origin-tls-* +
      # cloudflare-origin-pull-ca) live in the CLOUDFLARE stack: linked stacks
      # cannot publish sensitive values, so the Origin CA private key is
      # written into Secret Manager there and never crosses a stack boundary.
    }
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# --- Prod operator secret values (read back from Secret Manager) -------------
# The platform stack writes the Cloud SQL connection string and the GCS HMAC
# keys to Secret Manager at init. They are sensitive, so the platform can't
# publish them as linked outputs; this stack reads them back and hands them to
# the clouddeploy component as deploy parameters, which render the mattermost-db
# / mattermost-filestore Kubernetes Secrets the operator consumes. (The managed
# GKE Secret Manager add-on cannot sync secretObjects into Kubernetes Secrets,
# so the operator secrets are materialised this way instead of via CSI.)
component "prod_secret_values" {
  source = "./modules/secret-lookup"

  inputs = {
    project_id = var.project_id
    secret_ids = merge(
      {
        mattermost_db_connection      = "cloudsql-mattermost-connection"
        mattermost_storage_access_key = "mattermost-storage-access-key"
        mattermost_storage_secret_key = "mattermost-storage-secret-key"
      },
      # Origin CA cert/key written by the cloudflare stack; read only when a
      # public ingress exists (else the containers are empty/absent).
      var.manage_ingress_origin_tls ? {
        mattermost_origin_tls_cert = "mattermost-origin-tls-cert"
        mattermost_origin_tls_key  = "mattermost-origin-tls-key"
      } : {},
      # AOP client-cert CA (self-generated by the cloudflare stack, always
      # populated when a public ingress exists). Read whenever origin TLS is
      # managed -- NOT gated on aop_enabled -- so the ingress auth-tls-secret
      # always resolves; aop_enabled only toggles verify-client enforcement.
      var.manage_ingress_origin_tls ? {
        cloudflare_origin_pull_ca = "cloudflare-origin-pull-ca"
      } : {},
      # Google Workspace OAuth client for the google-workspace MCP server
      # (seeded by the secrets component above, so a version always exists).
      var.mcp_servers_enabled ? {
        mcp_terraform_hcp_token            = "mcp-terraform-hcp-token"
        mcp_google_workspace_client_id     = "mcp-google-workspace-client-id"
        mcp_google_workspace_client_secret = "mcp-google-workspace-client-secret"
      } : {},
      # cloudflared run token, written to Secret Manager by the cloudflare
      # stack's zero_trust component -- so the flag here must only be
      # enabled AFTER the cloudflare stack applied with its flag on.
      var.zero_trust_enabled ? {
        mcp_tunnel_token = "mcp-tunnel-token"
      } : {},
    )
  }

  providers = {
    google = provider.google.this
  }
}

# --- Tenant namespaces + credential Secrets (created directly, not via CD) ----
# The secure path for every credential the workloads consume as a Kubernetes
# Secret: Terraform writes them straight to etcd from Secret Manager / a
# generated password, so they never touch a Cloud Deploy deploy parameter or a
# rendered release. Terraform owns the namespaces so the Secrets exist before
# Cloud Deploy deploys the workloads into them (replacing helm/namespaces.yaml).
component "cluster_secrets" {
  source = "./modules/cluster-secrets"

  inputs = {
    # The matterbridge namespace only exists while matterbridge is enabled --
    # disabling it removes the (now empty) namespace on the next apply.
    namespaces = merge(
      {
        dev        = { labels = { tier = "dev", "part-of" = "yourown-chat" } }
        mattermost = { labels = { tier = "prod", "part-of" = "yourown-chat" } }
      },
      var.matterbridge_enabled ? {
        matterbridge = { labels = { tier = "dev", "part-of" = "yourown-chat" } }
      } : {},
    )
    adopt_existing_namespaces = var.adopt_existing_namespaces

    secrets = merge(
      {
        # dev in-cluster Postgres password (generated). Read by dev Postgres
        # (POSTGRES_PASSWORD) and dev Mattermost (secretKeyRef -> datasource).
        dev-postgres = {
          name      = "dev-postgres"
          namespace = "dev"
          labels    = { app = "dev-postgres" }
          data      = { POSTGRES_PASSWORD = component.secrets.generated_values["dev-postgres-password"] }
        }
        # prod external DB connection string (Cloud SQL), consumed by the operator
        # CR as spec.database.external.secret: mattermost-db.
        mattermost-db = {
          name      = "mattermost-db"
          namespace = "mattermost"
          labels    = { app = "mattermost" }
          data      = { DB_CONNECTION_STRING = component.prod_secret_values.values["mattermost_db_connection"] }
        }
        # prod external filestore (GCS S3-compatible HMAC keys), consumed by the
        # operator CR as spec.fileStore.external.secret: mattermost-filestore.
        mattermost-filestore = {
          name      = "mattermost-filestore"
          namespace = "mattermost"
          labels    = { app = "mattermost" }
          data = {
            accesskey = component.prod_secret_values.values["mattermost_storage_access_key"]
            secretkey = component.prod_secret_values.values["mattermost_storage_secret_key"]
          }
        }
      },
      # prod ingress Origin CA keypair (Cloudflare Full (Strict) TLS), served by
      # the Mattermost Ingress via spec.ingress.tlsSecret: mattermost-origin-tls.
      # Values are read from the cloudflare-written Secret Manager secrets (this
      # stack runs after cloudflare); type must be kubernetes.io/tls.
      var.manage_ingress_origin_tls ? {
        mattermost-origin-tls = {
          name      = "mattermost-origin-tls"
          namespace = "mattermost"
          type      = "kubernetes.io/tls"
          labels    = { app = "mattermost" }
          data = {
            "tls.crt" = component.prod_secret_values.values["mattermost_origin_tls_cert"]
            "tls.key" = component.prod_secret_values.values["mattermost_origin_tls_key"]
          }
        }
      } : {},
      # AOP client-cert CA (ingress auth-tls-secret). Created whenever origin TLS
      # is managed, NOT only when aop_enabled: ingress-nginx loads auth-tls-secret
      # regardless of verify-client, so a missing Secret fails annotation parsing
      # (HTTP 403). The CA is inert until aop_enabled flips verify-client to "on".
      var.manage_ingress_origin_tls ? {
        cloudflare-origin-pull-ca = {
          name      = "cloudflare-origin-pull-ca"
          namespace = "mattermost"
          labels    = { app = "mattermost" }
          data      = { "ca.crt" = component.prod_secret_values.values["cloudflare_origin_pull_ca"] }
        }
      } : {},
      # OAuth client for the google-workspace MCP server, consumed via
      # secretEnvFrom in helm/mcp-servers/values.yaml. Same secure path as the
      # rest: Secret Manager value -> Secret straight in etcd, never through
      # Cloud Deploy.
      var.mcp_servers_enabled ? {
        # HCP Terraform token for the terraform MCP server (TFE_TOKEN enables
        # the app.terraform.io workspace/run/stack tools).
        mcp-terraform-hcp = {
          name      = "mcp-terraform-hcp"
          namespace = "mattermost"
          labels    = { "app.kubernetes.io/part-of" = "mcp-servers" }
          data = {
            TFE_TOKEN = component.prod_secret_values.values["mcp_terraform_hcp_token"]
          }
        }
        mcp-google-workspace-oauth = {
          name      = "mcp-google-workspace-oauth"
          namespace = "mattermost"
          labels    = { "app.kubernetes.io/part-of" = "mcp-servers" }
          data = {
            GOOGLE_OAUTH_CLIENT_ID     = component.prod_secret_values.values["mcp_google_workspace_client_id"]
            GOOGLE_OAUTH_CLIENT_SECRET = component.prod_secret_values.values["mcp_google_workspace_client_secret"]
          }
        }
      } : {},
      # cloudflared run token for the Zero Trust tunnel pod (chart tunnel.enabled).
      var.zero_trust_enabled ? {
        mcp-tunnel = {
          name      = "mcp-tunnel"
          namespace = "mattermost"
          labels    = { "app.kubernetes.io/part-of" = "mcp-servers" }
          data = {
            TUNNEL_TOKEN = component.prod_secret_values.values["mcp_tunnel_token"]
          }
        }
      } : {},
    )
  }

  providers = {
    kubernetes = provider.kubernetes.this
  }
}

# --- dev-tenant RBAC (Terraform-owned, not Cloud Deploy) ---------------------
# The dev team's namespace-scoped Role/RoleBinding. Created by Terraform because
# Cloud Deploy's execution SA is roles/container.developer, which GKE forbids
# from creating RBAC objects (privilege-escalation prevention); the apply SA has
# container.admin and can. No subjects (default) => nothing is created.
component "dev_rbac" {
  source = "./modules/dev-rbac"

  inputs = {
    namespace = "dev"
    subjects  = var.dev_team_rbac_subjects
  }

  providers = {
    kubernetes = provider.kubernetes.this
  }
}

# --- Mattermost image CI (Cloud Build 2nd-gen) ------------------------------
# Links the source repo (pilprod/mattermost) to the shared, out-of-band GitHub
# connection (console OAuth), plus one least-privilege build SA (repo-scoped
# writer on the platform registry) and a tag-triggered build that pushes ONE
# image on a single tag pattern (^v.*-patched$), promoted dev -> prod by Cloud
# Deploy.
component "mattermost_image" {
  source = "./modules/cloudbuild-image"

  inputs = {
    project_id = var.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    # Existing, out-of-band Cloud Build connection (console OAuth) shared by the
    # image and deploy repos; Terraform only links repositories/triggers to it.
    connection_name   = var.github_connection_name
    github_remote_uri = var.github_remote_uri

    # Push every build to the ONE unified repository the platform stack owns.
    artifact_registry_location      = var.artifact_registry_location
    artifact_registry_repository_id = var.artifact_registry_repository_id

    image_name = var.image_name
    builds     = var.builds
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

# --- Automated release cutting (Cloud Build 2nd-gen on git tags) -------------
# Makes deployment hands-off: links the DEPLOY repo (this one, holds helm/) to the
# shared out-of-band GitHub connection, plus a least-privilege releaser SA and a
# tag trigger. On a semver tag (release_tag_regex, i.e. *.*.*) it runs `gcloud
# deploy releases create` against the clouddeploy pipeline, so a tag — not a human
# — cuts the release. The releaser can create releases on that pipeline only and
# actAs the execution SA; it never touches the image build.
component "deploy_release" {
  source = "./modules/deploy-release"

  inputs = {
    project_id = var.project_id
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

    # CMEK the private source-staging bucket with the platform's shared key
    # (null when the platform runs cmek_enabled = false), mirroring the other
    # data buckets.
    source_bucket_kms_key_name = var.cmek_key_id

    labels = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# --- Cluster bootstrap (auth lookup) -----------------------------------------
# Data-only: resolves the platform cluster's endpoint/CA from the published
# cluster ID and mints a short-lived apply-SA token. Its outputs configure the
# stack-level helm provider (providers.tfcomponent.hcl) -- a separate component
# from cluster_bootstrap because a component cannot both feed a provider's
# configuration and consume that provider.
component "gke_auth" {
  source = "./modules/gke-auth"

  inputs = {
    gke_cluster_id = var.gke_cluster_id
  }

  providers = {
    google = provider.google.this
  }
}

# --- Cluster bootstrap (releases) --------------------------------------------
# The cluster-scoped prerequisites for the helm/ workloads (docs/DEPLOY.md
# "One-time setup" step 2), installed automatically right after the platform
# cluster exists instead of a manual `helm upgrade --install`:
#   - Mattermost Operator + CRDs (prod Mattermost is an operator CR)
#   - ingress-nginx, pinned to the platform-published ingress IP and admitting
#     only Cloudflare source ranges (skipped when the IP is null)
component "cluster_bootstrap" {
  source = "./modules/cluster-bootstrap"

  inputs = {
    mattermost_operator_chart_version = var.mattermost_operator_chart_version
    ingress_nginx_chart_version       = var.ingress_nginx_chart_version
    adopt_existing_releases           = var.adopt_existing_cluster_bootstrap_releases

    # Platform-published "white address"; replaces the manual loadBalancerIP
    # step in helm/ingress-nginx/values.yaml (kept as the manual fallback).
    ingress_load_balancer_ip = var.ingress_ip_address
  }

  providers = {
    helm = provider.helm.this
  }
}
