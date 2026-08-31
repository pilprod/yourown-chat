# APP-GCP stack: the GCP delivery layer (secrets, Cloud Deploy, image CI,
# release cutting). Linked to platform-gcp via last-applied upstream outputs;
# the Cloudflare edge and origin-TLS secrets live in the cloudflare stack.

locals {
  common_labels = merge({
    environment = var.environment
    managed-by  = "terraform"
    stack       = "yourown-chat-app-gcp"
  }, var.extra_labels)

  # Cloud Deploy may upgrade the existing `kagent` release only after the
  # Terraform application resource has been retained in-cluster and removed
  # from state, the controller namespace handoff is complete, and both fork
  # CRD charts are owned by Terraform. None of these are inferred from a live
  # Helm status.
  kagent_substrate_crd_prerequisites_ready = alltrue([
    contains(keys(var.vendor_chart_bundles), "kagent"),
    try(var.vendor_chart_bundles["kagent"].provisioned, false),
    !try(var.vendor_chart_bundles["kagent"].application_enabled, true),
    try(var.vendor_chart_bundles["kagent"].charts.crds.ref, null) == try(var.kagent_substrate_delivery.artifacts["kagent"].charts.crds.ref, null),
    try(var.vendor_chart_bundles["kagent"].charts.crds.version, null) == try(var.kagent_substrate_delivery.artifacts["kagent"].charts.crds.version, null),
    var.kagent_substrate_delivery.crd_ownership_ready,
    var.kagent_substrate_delivery.controller_namespace_handoff_ready,
  ])
}

component "clouddeploy" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id
    pipeline_name  = "mattermost"
    release_manager_members = [
      var.workload_identity_members.mcp,
    ]

    stages = [
      {
        name             = "dev"
        profiles         = var.matterbridge_enabled ? ["mattermost-dev", "matterbridge"] : ["mattermost-dev"]
        require_approval = false
        verify           = true
      },
      {
        name              = "prod"
        profiles          = ["mattermost-prod"]
        require_approval  = true
        verify            = true
        predeploy_actions = ["cleanup-mattermost-dev"]
      },
    ]

    deploy_parameters = {
      filestore_bucket       = var.gcs_bucket_name
      mattermost_cloudsql_ip = var.cloudsql_private_ip
      mattermost_gsa         = var.workload_identity_emails.mattermost
      mattermost_dev_gsa     = var.workload_identity_emails.dev
      matterbridge_gsa       = var.workload_identity_emails.matterbridge
      aop_verify_client      = var.aop_enabled ? "on" : "off"
      mattermost_calls_ip    = var.calls_ip_address
    }

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

component "clouddeploy_mattermost_preview" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id
    pipeline_name  = "mattermost-preview"
    release_manager_members = [
      var.workload_identity_members.mcp,
    ]

    # Deliberately no production stage: a release-branch artifact cannot be
    # promoted to prod through Cloud Deploy, the UI, or the MCP.
    stages = [
      {
        name             = "dev"
        profiles         = var.matterbridge_enabled ? ["mattermost-dev", "matterbridge"] : ["mattermost-dev"]
        require_approval = false
        verify           = true
      },
    ]

    deploy_parameters = {
      filestore_bucket       = var.gcs_bucket_name
      mattermost_cloudsql_ip = var.cloudsql_private_ip
      mattermost_gsa         = var.workload_identity_emails.mattermost
      mattermost_dev_gsa     = var.workload_identity_emails.dev
      matterbridge_gsa       = var.workload_identity_emails.matterbridge
      aop_verify_client      = var.aop_enabled ? "on" : "off"
      mattermost_calls_ip    = var.calls_ip_address
    }

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

component "clouddeploy_mcp" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id
    pipeline_name  = "mcp"
    release_manager_members = [
      var.workload_identity_members.mcp,
    ]

    stages = [
      {
        name             = "dev"
        profiles         = ["mcp-dev"]
        require_approval = false
        verify           = false
      },
      {
        name              = "prod"
        profiles          = ["mcp-prod"]
        require_approval  = true
        verify            = true
        predeploy_actions = ["cleanup-mcp-dev"]
        postdeploy_actions = var.mcp_capability_sync_enabled ? [
          "sync-cloudflare-mcp-capabilities",
        ] : []
      },
    ]

    deploy_parameters = {
      mcp_secret_project       = var.project_id
      mcp_google_cloud_gsa     = lookup(var.workload_identity_emails, "mcp", "")
      mcp_google_cloud_dev_gsa = lookup(var.workload_identity_emails, "mcp-dev", "")
      mcp_terraform_stacks_gsa = lookup(var.workload_identity_emails, "mcp-terraform-stacks", "")
      mcp_tunnel_gsa           = lookup(var.workload_identity_emails, "mcp-tunnel", "")
    }

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

component "clouddeploy_kagent_substrate" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id              = var.project_id
    region                  = var.region
    gke_cluster_id          = var.gke_cluster_id
    pipeline_name           = "kagent-substrate"
    release_manager_members = [var.workload_identity_members.mcp]

    stages = [
      {
        name             = "dev"
        profiles         = ["kagent-dev"]
        require_approval = false
        verify           = true
      },
      {
        name             = "prod"
        profiles         = ["kagent-prod"]
        require_approval = true
        predeploy_actions = ["require-external-broker-smoke"]
        verify           = true
      },
    ]

    deploy_parameters = {
      agentgateway_gateway_class         = var.agentgateway_platform.gateway_class_name
      agentgateway_public_ip_address     = var.agentgateway_public_ip_address == null ? "" : var.agentgateway_public_ip_address
      agentgateway_public_ip_name        = var.agentgateway_public_ip_name == null ? "" : var.agentgateway_public_ip_name
      agentgateway_public_broker_address = var.agentgateway_public_ip_address == null ? "" : "${var.agentgateway_public_ip_address}:443"
      substrate_broker_service_name      = var.kagent_substrate_delivery.broker_service_name
      substrate_broker_service_port      = tostring(var.kagent_substrate_delivery.broker_service_port)
      substrate_broker_server_name       = var.kagent_substrate_delivery.broker_server_name
    }

    labels = local.common_labels
  }

  providers = {
    google      = provider.google.this
    google-beta = provider.google-beta.this
  }
}

component "clouddeploy_server" {
  source = "./modules/clouddeploy"

  inputs = {
    project_id     = var.project_id
    region         = var.region
    gke_cluster_id = var.gke_cluster_id
    pipeline_name  = "yourown-chat"
    release_manager_members = [
      var.workload_identity_members.mcp,
      "serviceAccount:backend-build@${var.project_id}.iam.gserviceaccount.com",
    ]

    stages = [{
      name             = "pilot"
      profiles         = ["server-pilot"]
      require_approval = true
      verify           = true
    }]

    deploy_parameters = {
      backend_control_api_gsa                        = lookup(var.workload_identity_emails, "backend-control-api", "")
      auth_api_gsa                                   = lookup(var.workload_identity_emails, "auth-api", "")
      transport_api_gsa                              = lookup(var.workload_identity_emails, "transport-api", "")
      identity_api_gsa                               = lookup(var.workload_identity_emails, "identity-api", "")
      identity_admin_gsa                             = lookup(var.workload_identity_emails, "identity-admin", "")
      identity_migrate_gsa                           = lookup(var.workload_identity_emails, "identity-migrate", "")
      server_secret_project                          = var.project_id
      identity_runtime_database_connection_secret_id = var.yourown_chat_identity_runtime_connection_secret_id
      identity_migrate_database_connection_secret_id = var.yourown_chat_identity_connection_secret_id
      identity_bootstrap_password_secret_id          = var.identity_bootstrap_user_password_secret_id
      transport_private_key_secret_id                = "yourown-chat-transport-private-key"
      passkey_record_key_secret_id                   = "yourown-chat-passkey-record-key"
      apple_association_app_id                       = var.apple_association_app_id
      cloudsql_private_ip                            = var.cloudsql_private_ip
      cluster_dns_ip                                 = var.cluster_dns_ip
      yourown_chat_control_api_enabled               = tostring(var.temporal_enabled)
      yourown_chat_ingress_enabled                   = tostring(var.manage_ingress_origin_tls)
      yourown_chat_registration_enabled              = tostring(var.yourown_chat_registration_enabled)
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

    secrets = merge(
      {
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
          # Cross-namespace ClusterIP access is intentionally denied. The
          # bridge uses the public Cloudflare-fronted endpoint instead.
          Server="yourown.chat"
          NoTLS=false
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
        # Seed placeholders so app-gcp can safely materialize the Kubernetes
        # Secret while Google login remains disabled. Add real Secret Manager
        # versions before setting mattermost_google_auth_enabled=true.
        "mattermost-google-client-id" = {
          value     = "REPLACE_ME_GOOGLE_CLIENT_ID"
          accessors = []
        }
        "mattermost-google-client-secret" = {
          value     = "REPLACE_ME_GOOGLE_CLIENT_SECRET"
          accessors = []
        }
        # Use a separate OAuth client for dev so its redirect URI and credential
        # can be tested and rotated without expanding the production client's
        # trust boundary.
        "dev-mattermost-google-client-id" = {
          value     = "REPLACE_ME_DEV_GOOGLE_CLIENT_ID"
          accessors = []
        }
        "dev-mattermost-google-client-secret" = {
          value     = "REPLACE_ME_DEV_GOOGLE_CLIENT_SECRET"
          accessors = []
        }
        # MCP credentials are read directly by GKE's Secret Manager CSI add-on.
        # Terraform manages only containers/IAM and never reads current values.
        "mcp-terraform-hcp-token" = {
          value     = "REPLACE_ME_HCP_TEAM_TOKEN"
          accessors = [var.workload_identity_members["mcp-terraform-stacks"]]
        }
        "backend-control-api-token" = {
          generate  = true
          special   = false
          accessors = [var.workload_identity_members["backend-control-api"]]
        }
        "yourown-chat-identity-admin-token" = {
          generate  = true
          special   = false
          accessors = [var.workload_identity_members["identity-admin"]]
        }
        "yourown-chat-passkey-record-key" = {
          generate  = true
          length    = 64
          special   = false
          accessors = [var.workload_identity_members["auth-api"]]
        }
        # The hybrid X-Wing private key is generated out-of-band after review.
        # Terraform owns only the empty container and least-privilege IAM so the
        # private value never enters HCL, plan output or Terraform state.
        "yourown-chat-transport-private-key" = {
          accessors = [var.workload_identity_members["transport-api"]]
        }
      },
      var.kagent_substrate_delivery.bootstrap_enabled ? {
        # External Substrate control-plane credential containers. Values are
        # populated and synchronized to native Kubernetes Secrets only through a
        # separately reviewed bootstrap; Terraform never reads PEM or pool JSON.
        "substrate-ate-api-tls" = {
          accessors = []
        }
        "substrate-ate-controller-tls" = {
          accessors = []
        }
        "substrate-atenet-egress-server-tls" = {
          accessors = []
        }
        "substrate-atenet-egress-client-tls" = {
          accessors = []
        }
        "substrate-actor-id-jwt-pool" = {
          accessors = []
        }
        "substrate-actor-id-ca-pool" = {
          accessors = []
        }
        "kagent-ate-client-tls" = {
          accessors = []
        }
        "kagent-dev-ate-client-tls" = {
          accessors = []
        }
      } : {},
    )
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}

# Reads the non-MCP application secrets that must still become native
# Kubernetes Secrets for Mattermost/operator compatibility. MCP credentials use
# CSI and deliberately never enter Terraform state or etcd.
component "prod_secret_values" {
  source = "./modules/secret-lookup"

  inputs = {
    project_id = var.project_id
    secret_ids = merge(
      {
        mattermost_db_connection      = "cloudsql-mattermost-connection"
        mattermost_storage_access_key = "mattermost-storage-access-key"
        mattermost_storage_secret_key = "mattermost-storage-secret-key"
        # Full resource IDs create a graph edge to the new containers/initial
        # versions, so the first app-gcp plan does not try to read them early.
        mattermost_google_client_id         = component.secrets.secret_resource_ids["mattermost-google-client-id"]
        mattermost_google_client_secret     = component.secrets.secret_resource_ids["mattermost-google-client-secret"]
        dev_mattermost_google_client_id     = component.secrets.secret_resource_ids["dev-mattermost-google-client-id"]
        dev_mattermost_google_client_secret = component.secrets.secret_resource_ids["dev-mattermost-google-client-secret"]
      },
      var.manage_ingress_origin_tls ? {
        mattermost_origin_tls_cert = "mattermost-origin-tls-cert"
        mattermost_origin_tls_key  = "mattermost-origin-tls-key"
        # Not gated on aop_enabled: ingress-nginx loads auth-tls-secret even
        # with verify-client off, and a missing Secret 403s the whole host.
        cloudflare_origin_pull_ca = "cloudflare-origin-pull-ca"
      } : {},
    )
  }

  providers = {
    google = provider.google.this
  }
}

# Namespaces + application Secrets. MCP namespaces remain owned here,
# but MCP credentials are mounted directly from Secret Manager by their pods.
component "cluster_secrets" {
  source = "./modules/cluster-secrets"

  inputs = {
    namespaces = merge(
      {
        dev             = { labels = { tier = "dev", "part-of" = "yourown-chat" } }
        mattermost      = { labels = { tier = "prod", "part-of" = "yourown-chat" } }
        mattermost-rtcd = { labels = { tier = "prod", "part-of" = "yourown-chat", "component" = "rtcd" } }
        # Every MCP server is an independent tenant.  This prevents a
        # compromised server from reaching another server merely because both
        # happen to be MCP workloads.  The Tunnel connector is isolated too.
        mcp-terraform-stacks = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-server" = "terraform-stacks" } }
        mcp-google-cloud     = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-server" = "google-cloud" } }
        mcp-tunnel           = { labels = { tier = "prod", "part-of" = "yourown-chat", "mcp-component" = "tunnel" } }
      },
      var.matterbridge_enabled ? {
        matterbridge = { labels = { tier = "dev", "part-of" = "yourown-chat" } }
      } : {},
      var.yourown_chat_server_enabled ? {
        edge = {
          labels = {
            tier                                         = "pilot"
            "part-of"                                    = "yourown-chat"
            component                                    = "edge"
            "pod-security.kubernetes.io/enforce"         = "restricted"
            "pod-security.kubernetes.io/enforce-version" = "latest"
            "pod-security.kubernetes.io/audit"           = "restricted"
            "pod-security.kubernetes.io/warn"            = "restricted"
          }
        }
        identity = {
          labels = {
            tier                                         = "pilot"
            "part-of"                                    = "yourown-chat"
            component                                    = "identity"
            "pod-security.kubernetes.io/enforce"         = "restricted"
            "pod-security.kubernetes.io/enforce-version" = "latest"
            "pod-security.kubernetes.io/audit"           = "restricted"
            "pod-security.kubernetes.io/warn"            = "restricted"
          }
        }
        control = {
          labels = {
            tier                                         = "pilot"
            "part-of"                                    = "yourown-chat"
            component                                    = "control"
            "pod-security.kubernetes.io/enforce"         = "restricted"
            "pod-security.kubernetes.io/enforce-version" = "latest"
            "pod-security.kubernetes.io/audit"           = "restricted"
            "pod-security.kubernetes.io/warn"            = "restricted"
          }
        }
      } : {},
    )
    adopt_existing_namespaces = var.adopt_existing_namespaces

    storage_classes = {
      rtcd-cmek = {
        provisioner = "pd.csi.storage.gke.io"
        parameters = {
          type                    = "pd-standard"
          disk-encryption-kms-key = var.cmek_key_id
        }
        reclaim_policy         = "Retain"
        volume_binding_mode    = "WaitForFirstConsumer"
        allow_volume_expansion = true
      }
    }

    secrets = merge(
      {
        dev-postgres = {
          name      = "dev-postgres"
          namespace = "dev"
          labels    = { app = "dev-postgres" }
          data      = { POSTGRES_PASSWORD = component.secrets.generated_values["dev-postgres-password"] }
        }
        dev-mattermost-google-auth = {
          name      = "dev-mattermost-google-auth"
          namespace = "dev"
          labels    = { app = "dev-mattermost" }
          data = {
            "client-id"     = component.prod_secret_values.values["dev_mattermost_google_client_id"]
            "client-secret" = component.prod_secret_values.values["dev_mattermost_google_client_secret"]
          }
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
        mattermost-google-auth = {
          name      = "mattermost-google-auth"
          namespace = "mattermost"
          labels    = { app = "mattermost" }
          data = {
            "client-id"     = component.prod_secret_values.values["mattermost_google_client_id"]
            "client-secret" = component.prod_secret_values.values["mattermost_google_client_secret"]
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
      var.manage_ingress_origin_tls && var.yourown_chat_server_enabled ? {
        edge-origin-tls = {
          name      = "yourown-chat-server-origin-tls"
          namespace = "edge"
          type      = "kubernetes.io/tls"
          labels    = { app = "server" }
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
    repository_name   = var.source_repositories.mattermost.name
    github_remote_uri = var.source_repositories.mattermost.remote_uri

    web_repository_name      = var.source_repositories.web.name
    web_github_remote_uri    = var.source_repositories.web.remote_uri
    server_source_remote_uri = var.source_repositories.server_source.remote_uri

    artifact_registry_location      = var.artifact_registry_location
    artifact_registry_repository_id = var.artifact_registry_repository_id

    image_name = var.image_name
    builds     = var.builds

    mattermost_deliveries = {
      production = {
        pipeline_name                   = component.clouddeploy.delivery_pipeline_name
        initial_target_name             = component.clouddeploy.target_names["dev"]
        execution_service_account_email = component.clouddeploy.execution_service_account_email
        deploy_repository_uri           = var.source_repositories.deploy.remote_uri
        deploy_repository_ref           = "main"
        source_bucket_name              = component.deploy_release.source_bucket_name
      }
      preview = {
        pipeline_name                   = component.clouddeploy_mattermost_preview.delivery_pipeline_name
        initial_target_name             = component.clouddeploy_mattermost_preview.target_names["dev"]
        execution_service_account_email = component.clouddeploy_mattermost_preview.execution_service_account_email
        deploy_repository_uri           = var.source_repositories.deploy.remote_uri
        deploy_repository_ref           = "main"
        source_bucket_name              = component.deploy_release.source_bucket_name
      }
    }
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
    repository_name   = var.source_repositories.deploy.name
    github_remote_uri = var.source_repositories.deploy.remote_uri

    backend_repository_name   = var.source_repositories.backend.name
    backend_github_remote_uri = var.source_repositories.backend.remote_uri
    mcp_repository_name       = var.source_repositories.mcp.name
    mcp_github_remote_uri     = var.source_repositories.mcp.remote_uri
    rtcd_repository_name      = var.source_repositories.rtcd.name
    rtcd_github_remote_uri    = var.source_repositories.rtcd.remote_uri
    mcp_release_tag_regex     = var.mcp_release_tag_regex
    backend_release_tag_regex = var.backend_release_tag_regex

    delivery_pipelines = {
      mattermost = {
        execution_service_account_email = component.clouddeploy.execution_service_account_email
      }
      mattermost-preview = {
        execution_service_account_email = component.clouddeploy_mattermost_preview.execution_service_account_email
      }
      mcp = {
        execution_service_account_email = component.clouddeploy_mcp.execution_service_account_email
      }
      yourown-chat = {
        execution_service_account_email = component.clouddeploy_server.execution_service_account_email
      }
      kagent-substrate = {
        execution_service_account_email = component.clouddeploy_kagent_substrate.execution_service_account_email
      }
    }

    release_tag_regex         = var.release_tag_regex
    mcp_enabled               = var.mcp_servers_enabled
    server_enabled            = var.yourown_chat_server_enabled
    kagent_substrate_delivery = var.kagent_substrate_delivery
    kagent_substrate_prerequisites_ready = (
      var.kagent_substrate_delivery.release_enabled &&
      var.kagent_substrate_delivery.native_secret_sync_ready &&
      local.kagent_substrate_crd_prerequisites_ready &&
      component.substrate_prerequisites.release_ready &&
      var.agentgateway_platform.enabled &&
      var.agentgateway_public_ip_address != null &&
      var.agentgateway_public_ip_name != null
    )
    mattermost_image_repository = {
      location      = var.artifact_registry_location
      repository_id = var.artifact_registry_repository_id
      image_name    = var.image_name
    }

    source_bucket_kms_key_name = var.cmek_key_id

    # Wrapper-based delivery through the platform workload profiles. The
    # switch defaults to false; the chart repository comes from platform-gcp
    # and is filled by the separate chart publication rail.
    wrapper_releases_enabled = var.wrapper_releases_enabled
    helm_chart_repository = var.helm_registry_repository_id == null ? null : {
      location      = var.artifact_registry_location
      repository_id = var.helm_registry_repository_id
    }
    workload_identity_emails = var.workload_identity_emails
    cluster_dns_ip           = var.cluster_dns_ip

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

# The general pool relies on Kubernetes scheduling policy rather than permanent
# per-environment VMs: prod can preempt dev, while the dev namespace has a hard
# compute budget and safe defaults. RTCD uses the same pool with production
# priority and explicit requests so idle media capacity does not require a VM.
component "workload_scheduling" {
  source = "./modules/workload-scheduling"

  depends_on = [component.cluster_secrets]

  inputs = {
    server_enabled = var.yourown_chat_server_enabled
    cleanup_service_account_emails = {
      mattermost = component.clouddeploy.cleanup_service_account_email
      mcp        = component.clouddeploy_mcp.cleanup_service_account_email
    }
  }

  providers = {
    kubernetes = provider.kubernetes.this
  }
}

# Persistent dev database is deliberately outside Cloud Deploy. Mattermost dev
# pods come and go, while Terraform retains the database and schema so every
# new image validates real sequential migrations.
component "dev_postgres" {
  source = "./modules/dev-postgres"

  depends_on = [component.cluster_secrets, component.workload_scheduling]

  providers = {
    kubernetes = provider.kubernetes.this
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

# Generic adapter for service-owned OCI chart bundles declared alongside this
# Stack. Credentials remain outside the repository.
component "vendor_chart_bundle" {
  # Keep disabled entries instantiated so the module-level CRD
  # prevent_destroy guard remains present during staged retirement.
  for_each = var.vendor_chart_bundles

  source = "./modules/vendor-chart-bundle"

  # A bundle may add an exact egress flow in an existing external namespace,
  # so the shared namespace owner must finish first.
  depends_on = [component.cluster_secrets]

  inputs = {
    bundle_key          = each.key
    bundle              = each.value
    project_id          = var.project_id
    database_secret_ids = var.additional_cloudsql_connection_secret_ids
    cloudsql_private_ip = var.cloudsql_private_ip
    cluster_dns_ip      = var.cluster_dns_ip
    labels              = local.common_labels
  }

  providers = {
    helm       = provider.helm.this
    kubernetes = provider.kubernetes.this
  }
}

# Canonical-branch publication of platform Helm chart versions as immutable
# OCI artifacts into the dedicated Helm chart repository published by
# platform-gcp (helm_registry_repository_id). Service wrappers in owning
# repositories pin these versions (docs/HELM_PLATFORM.md). The rail stays
# unmaterialized until platform-gcp publishes the repository; it reuses the
# deploy repository link owned by deploy_release and keeps its own durable
# evidence bucket. It creates no Cloud Deploy release and deploys nothing.
component "substrate_prerequisites" {
  source = "./modules/substrate-prerequisites"

  inputs = {
    adopt_existing                                   = var.adopt_existing_substrate
    adopt_existing_substrate_compatibility_confirmed = var.adopt_existing_substrate_compatibility_confirmed
    bootstrap_enabled                                = var.kagent_substrate_delivery.bootstrap_enabled
    release_enabled                                  = var.kagent_substrate_delivery.release_enabled
    gke_cluster_id                                   = var.gke_cluster_id
    native_secret_sync_ready                         = var.kagent_substrate_delivery.native_secret_sync_ready
    external_broker_smoke_ready                      = var.kagent_substrate_delivery.external_broker_smoke_ready
    external_broker_smoke_release                    = var.kagent_substrate_delivery.external_broker_smoke_release
    promotion_gate_reader_email                      = component.clouddeploy_kagent_substrate.cleanup_service_account_email
    cloudsql_private_ip                              = var.cloudsql_private_ip
    cluster_dns_ip                                   = var.cluster_dns_ip
    local_provider_only                              = var.kagent_substrate_delivery.local_provider_only
    atenet_egress_destinations                       = var.kagent_substrate_delivery.atenet_egress_destinations
    substrate_crd_chart                              = try(var.kagent_substrate_delivery.artifacts["substrate"].charts.crds, { ref = "", version = "" })
    substrate_application_chart = try(
      var.kagent_substrate_delivery.artifacts["substrate"].charts.application,
      { ref = "", version = "" },
    )
    substrate_helm_set_values = try(var.kagent_substrate_delivery.helm_set_values["substrate"], {})
    substrate_values_sha256   = try(var.kagent_substrate_delivery.values_sha256["kagent/substrate.values.yaml"], "")
    kagent_control_planes = {
      prod = {
        namespace    = var.vendor_chart_bundles["kagent"].namespaces["control"].name
        release_name = "kagent"
        agent_namespaces = {
          codex = var.vendor_chart_bundles["kagent"].namespaces["codex"].name
        }
      }
      dev = {
        namespace    = var.vendor_chart_bundles["kagent"].namespaces["dev_control"].name
        release_name = "kagent-dev"
        agent_namespaces = {
          codex = var.vendor_chart_bundles["kagent"].namespaces["dev_codex"].name
        }
      }
    }
    secret_contract = {
      postgres = {
        secret_manager_id = lookup(var.additional_cloudsql_connection_secret_ids, "substrate", "")
        namespace         = "ate-system"
        kubernetes_name   = "substrate-cloud-sql"
        keys              = ["connection-string"]
      }
      api_tls = {
        secret_manager_id = try(component.secrets.secret_ids["substrate-ate-api-tls"], "")
        namespace         = "ate-system"
        kubernetes_name   = "substrate-ate-api-tls"
        keys              = ["server-credential-bundle.pem", "client-ca.pem"]
      }
      controller_tls = {
        secret_manager_id = try(component.secrets.secret_ids["substrate-ate-controller-tls"], "")
        namespace         = "ate-system"
        kubernetes_name   = "substrate-ate-controller-tls"
        keys              = ["client-credential-bundle.pem", "server-ca.pem"]
      }
      egress_gateway_tls = {
        secret_manager_id = try(component.secrets.secret_ids["substrate-atenet-egress-server-tls"], "")
        namespace         = "ate-system"
        kubernetes_name   = "substrate-atenet-egress-server-tls"
        keys              = ["server-credential-bundle.pem", "server-ca.pem"]
      }
      egress_authorizer_tls = {
        secret_manager_id = try(component.secrets.secret_ids["substrate-atenet-egress-client-tls"], "")
        namespace         = "ate-system"
        kubernetes_name   = "substrate-atenet-egress-client-tls"
        keys              = ["client-credential-bundle.pem", "server-ca.pem"]
      }
      actor_id_jwt_pool = {
        secret_manager_id = try(component.secrets.secret_ids["substrate-actor-id-jwt-pool"], "")
        namespace         = "ate-system"
        kubernetes_name   = "actor-id-jwt-pool"
        keys              = ["pool"]
      }
      actor_id_ca_pool = {
        secret_manager_id = try(component.secrets.secret_ids["substrate-actor-id-ca-pool"], "")
        namespace         = "ate-system"
        kubernetes_name   = "actor-id-ca-pool"
        keys              = ["pool"]
      }
      kagent_client_tls = {
        secret_manager_id = try(component.secrets.secret_ids["kagent-ate-client-tls"], "")
        namespace         = "kagent-system"
        kubernetes_name   = "kagent-ate-client-tls"
        keys              = ["client-credential-bundle.pem", "server-ca.pem"]
      }
      kagent_dev_client_tls = {
        secret_manager_id = try(component.secrets.secret_ids["kagent-dev-ate-client-tls"], "")
        namespace         = "kagent-dev"
        kubernetes_name   = "kagent-dev-ate-client-tls"
        keys              = ["client-credential-bundle.pem", "server-ca.pem"]
      }
    }
    derived_secret_contract = {
      actor_id_ca_certs = {
        source_secret_key = "actor_id_ca_pool"
        namespace         = "ate-system"
        kubernetes_name   = "actor-id-ca-certs"
        keys              = ["ca.crt"]
      }
    }
    agentgateway = {
      namespace                  = var.agentgateway_platform.namespace
      service_account_name       = var.agentgateway_platform.service_account_name
      deployer_cluster_role_name = var.agentgateway_platform.deployer_cluster_role_name
      public_ip_name             = var.agentgateway_public_ip_name == null ? "" : var.agentgateway_public_ip_name
    }
    labels = local.common_labels
  }

  providers = {
    helm       = provider.helm.this
    kubernetes = provider.kubernetes.this
  }

  depends_on = [component.vendor_chart_bundle]
}

component "chart_publish" {
  source = "./modules/chart-publish"

  inputs = {
    project_id = var.project_id
    region     = var.region

    apply_service_account_email = var.service_account_email

    repository_id = component.deploy_release.repository_id

    chart_repository = var.helm_registry_repository_id == null ? null : {
      location      = var.artifact_registry_location
      repository_id = var.helm_registry_repository_id
    }

    evidence_kms_key_name = var.cmek_key_id
    labels                = local.common_labels
  }

  providers = {
    google = provider.google.this
  }
}

component "kagent_preview_publisher" {
  source = "./modules/kagent-preview-publisher"

  inputs = {
    enabled = var.kagent_preview_publisher.enabled

    project_id                  = var.project_id
    region                      = var.region
    apply_service_account_email = var.service_account_email
    submitter_members = setunion(
      var.kagent_preview_publisher.submitter_members,
      toset([var.workload_identity_members.mcp]),
    )

    github_remote_uri = var.source_repositories.kagent.remote_uri
    source_commit     = var.kagent_preview_publisher.source_commit
    release_tag_regex = var.kagent_preview_publisher.release_tag_regex

    artifact_registry_location      = var.kagent_registry_location
    artifact_registry_repository_id = var.kagent_registry_repository_id
    staging_registry_repository_id  = var.kagent_staging_registry_repository_id

    evidence_bucket_name       = var.kagent_preview_publisher.evidence_bucket_name
    evidence_retention_seconds = var.kagent_preview_publisher.evidence_retention_seconds
    ghcr_secret_id             = var.kagent_preview_publisher.ghcr_secret_id
    kms_key_name               = var.cmek_key_id
    labels                     = local.common_labels
  }

  providers = {
    google = provider.google.this
    random = provider.random.this
  }
}
