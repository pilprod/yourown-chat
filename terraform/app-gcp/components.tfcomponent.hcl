# APP-GCP stack: the GCP delivery layer (secrets, Cloud Deploy, image CI,
# release cutting). Linked to platform-gcp via last-applied upstream outputs;
# the Cloudflare edge and origin-TLS secrets live in the cloudflare stack.

locals {
  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-app-gcp"
  }, var.extra_labels)
}

component "clouddeploy" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id

    stages = [
      {
        name             = "dev"
        profiles         = var.matterbridge_enabled ? ["dev", "matterbridge"] : ["dev"]
        require_approval = false
        verify           = true
      },
      { name = "prod", profiles = ["prod"], require_approval = true, verify = false },
    ]

    mcp_servers_enabled = var.mcp_servers_enabled

    # Substituted into `# from-param: ${...}` manifest markers on each release.
    # Credentials are deliberately NOT deploy parameters (they would land in
    # pipeline config and release renders) -- cluster_secrets writes those
    # straight to etcd.
    deploy_parameters = {
      filestore_bucket   = var.gcs_bucket_name
      mattermost_gsa     = var.workload_identity_emails.mattermost
      mattermost_dev_gsa = var.workload_identity_emails.dev
      matterbridge_gsa   = var.workload_identity_emails.matterbridge
      aop_verify_client  = var.aop_enabled ? "on" : "off"
      # lookup(): the `mcp` key exists only after the platform stack applies
      # its workload_identity_mcp component; empty keeps this stack planning.
      mcp_gsa = lookup(var.workload_identity_emails, "mcp", "")
    }

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

component "secrets" {
  source = "./modules/secrets"

  inputs = {
    project_id        = var.project_id
    replica_locations = [var.region]
    labels            = local.common_labels
    kms_key_name      = var.cmek_key_id

    secrets = {
      # special = false: the value is embedded in a postgres:// DSN, where
      # @ : / would corrupt the URL.
      "dev-postgres-password" = {
        generate  = true
        special   = false
        accessors = [var.workload_identity_members.dev]
      }
      # Seeded default so the CSI mount has >=1 version and the pod starts;
      # gateway ships disabled. Go live by adding a new version out-of-band:
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
      # MCP credentials, seeded with placeholders so pods always start; load
      # real values out-of-band (docs/MCP.md) and restart the pods.
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
    }
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# Reads sensitive values back from Secret Manager (linked stacks cannot publish
# sensitive outputs). Ordering: the cloudflare stack must have applied first
# for the origin-TLS / tunnel entries to exist.
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
      var.manage_ingress_origin_tls ? {
        mattermost_origin_tls_cert = "mattermost-origin-tls-cert"
        mattermost_origin_tls_key  = "mattermost-origin-tls-key"
        # Not gated on aop_enabled: ingress-nginx loads auth-tls-secret even
        # with verify-client off, and a missing Secret 403s the whole host.
        cloudflare_origin_pull_ca = "cloudflare-origin-pull-ca"
      } : {},
      # Created by component.secrets in THIS stack -- pass the computed full
      # resource path (not a literal id) so the read defers to apply time and
      # does not 404 before the secret exists.
      var.mcp_servers_enabled ? {
        mcp_terraform_hcp_token            = component.secrets.secret_resource_ids["mcp-terraform-hcp-token"]
        mcp_google_workspace_client_id     = component.secrets.secret_resource_ids["mcp-google-workspace-client-id"]
        mcp_google_workspace_client_secret = component.secrets.secret_resource_ids["mcp-google-workspace-client-secret"]
      } : {},
      var.zero_trust_enabled ? {
        mcp_tunnel_token = "mcp-tunnel-token"
      } : {},
    )
  }

  providers = {
    google = provider.google.this
  }
}

# Namespaces + credential Secrets written straight to etcd, so no secret ever
# passes through Cloud Deploy.
component "cluster_secrets" {
  source = "./modules/cluster-secrets"

  inputs = {
    namespaces = merge(
      {
        dev        = { labels = { tier = "dev", "part-of" = "yourown-chat" } }
        mattermost = { labels = { tier = "prod", "part-of" = "yourown-chat" } }
        # Every MCP server is an independent tenant.  This prevents a
        # compromised server from reaching another server merely because both
        # happen to be MCP workloads.  The Tunnel connector is isolated too.
        mcp-terraform        = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-server" = "terraform" } }
        mcp-google-cloud     = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-server" = "google-cloud" } }
        mcp-google-workspace = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-server" = "google-workspace" } }
        mcp-tunnel           = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-component" = "tunnel" } }
      },
      var.matterbridge_enabled ? {
        matterbridge = { labels = { tier = "dev", "part-of" = "yourown-chat" } }
      } : {},
    )
    adopt_existing_namespaces = var.adopt_existing_namespaces

    secrets = merge(
      {
        dev-postgres = {
          name      = "dev-postgres"
          namespace = "dev"
          labels    = { app = "dev-postgres" }
          data      = { POSTGRES_PASSWORD = component.secrets.generated_values["dev-postgres-password"] }
        }
        mattermost-db = {
          name      = "mattermost-db"
          namespace = "mattermost"
          labels    = { app = "mattermost" }
          data      = { DB_CONNECTION_STRING = component.prod_secret_values.values["mattermost_db_connection"] }
        }
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
      # Separate ternary (shape differs from mattermost-origin-tls, which has
      # `type`): merging two differently-typed objects in one map breaks the
      # cond ? {...} : {} type unification. Created whenever origin TLS is
      # managed, not only when AOP is on -- a missing auth-tls-secret 403s nginx.
      var.manage_ingress_origin_tls ? {
        cloudflare-origin-pull-ca = {
          name      = "cloudflare-origin-pull-ca"
          namespace = "mattermost"
          labels    = { app = "mattermost" }
          data      = { "ca.crt" = component.prod_secret_values.values["cloudflare_origin_pull_ca"] }
        }
      } : {},
      var.mcp_servers_enabled ? {
        mcp-terraform-hcp = {
          name      = "mcp-terraform-hcp"
          namespace = "mcp-terraform"
          labels    = { "app.kubernetes.io/part-of" = "mcp-servers" }
          data = {
            TFE_TOKEN = component.prod_secret_values.values["mcp_terraform_hcp_token"]
          }
        }
        mcp-google-workspace-oauth = {
          name      = "mcp-google-workspace-oauth"
          namespace = "mcp-google-workspace"
          labels    = { "app.kubernetes.io/part-of" = "mcp-servers" }
          data = {
            GOOGLE_OAUTH_CLIENT_ID     = component.prod_secret_values.values["mcp_google_workspace_client_id"]
            GOOGLE_OAUTH_CLIENT_SECRET = component.prod_secret_values.values["mcp_google_workspace_client_secret"]
          }
        }
      } : {},
      var.zero_trust_enabled ? {
        mcp-tunnel = {
          name      = "mcp-tunnel"
          namespace = "mcp-tunnel"
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

# Terraform-owned because Cloud Deploy's execution SA (container.developer) is
# forbidden by GKE from creating RBAC objects.
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

component "mattermost_image" {
  source = "./modules/cloudbuild-image"

  inputs = {
    project_id = var.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    connection_name   = var.github_connection_name
    github_remote_uri = var.github_remote_uri

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

# Semver tag on the deploy repo -> `gcloud deploy releases create`.
component "deploy_release" {
  source = "./modules/deploy-release"

  inputs = {
    project_id = var.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    connection_name   = var.github_connection_name
    github_remote_uri = var.github_deploy_remote_uri

    delivery_pipeline_name          = component.clouddeploy.delivery_pipeline_name
    execution_service_account_email = component.clouddeploy.execution_service_account_email

    release_tag_regex = var.release_tag_regex

    source_bucket_kms_key_name = var.cmek_key_id

    labels = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

# Data-only cluster auth; separate from cluster_bootstrap because a component
# cannot both feed a provider's configuration and consume that provider.
component "gke_auth" {
  source = "./modules/gke-auth"

  inputs = {
    gke_cluster_id = var.gke_cluster_id
  }

  providers = {
    google = provider.google.this
  }
}

# Mattermost Operator + ingress-nginx Helm releases, installed at apply.
component "cluster_bootstrap" {
  source = "./modules/cluster-bootstrap"

  inputs = {
    mattermost_operator_chart_version = var.mattermost_operator_chart_version
    ingress_nginx_chart_version       = var.ingress_nginx_chart_version
    adopt_existing_releases           = var.adopt_existing_cluster_bootstrap_releases

    ingress_load_balancer_ip = var.ingress_ip_address
  }

  providers = {
    helm = provider.helm.this
  }
}
