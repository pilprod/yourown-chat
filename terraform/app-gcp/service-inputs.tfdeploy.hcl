# Service-owned values consumed only by the existing app-gcp Stack.
# These are configuration and immutable release pins, not credentials.
locals {
  github_connection_name = "pilprod-github"

  source_repositories = {
    # Public platform repository: helm/ render root and release-tag source.
    deploy = {
      name       = "yourown-chat"
      remote_uri = "https://github.com/pilprod/yourown-chat.git"
    }
    # Product assembly (release owner of the Mattermost runtime).
    mattermost = {
      name       = "yourown-chat-mattermost"
      remote_uri = "https://github.com/pilprod/yourown-chat-mattermost.git"
    }
    # Private web source pinned by the assembly submodule.
    web = {
      name       = "yourown-chat-web"
      remote_uri = "https://github.com/pilprod/yourown-chat-web.git"
    }
    # Patched server source; provenance URL only, no Cloud Build link.
    server_source = {
      name       = "mattermost"
      remote_uri = "https://github.com/pilprod/mattermost.git"
    }
    backend = {
      name       = "yourown-chat-server"
      remote_uri = "https://github.com/pilprod/yourown-chat-server.git"
    }
    agents = {
      name       = "yourown-chat-agents"
      remote_uri = "https://github.com/pilprod/yourown-chat-agents.git"
    }
    mcp = {
      name       = "yourown-chat-mcp"
      remote_uri = "https://github.com/pilprod/yourown-chat-mcp.git"
    }
    # Product owner for the pinned Kagent integration and testbed profile.
    kagent = {
      name       = "kagent"
      remote_uri = "https://github.com/pilprod/kagent.git"
    }
    # Current (legacy) RTCD input kept verbatim so the first app-gcp plan is
    # a no-op. Switching to pilprod/rtcd is a catalog-only change owned by the
    # RTCD consolidation task (it recreates the Cloud Build link/trigger).
    rtcd = {
      name       = "yourown-chat-rtcd"
      remote_uri = "https://github.com/pilprod/yourown-chat-rtcd.git"
    }
  }

  vendor_chart_bundles = {
    kagent = {
      provisioned = true
      # Keep Terraform ownership until a reviewed two-step destroy=false state
      # retention handoff and Cloud Deploy activation are executed together.
      application_enabled = true
      deployment_class    = "testbed"
      production_eligible = false
      candidate_tag       = "testbed-20260823-2"
      product_commit      = "46436057e55b39fa704d3cbd8fda571f6bb238d8"
      source_commit       = "b45990582595acea5f6e765b86a10b251c50d5c9"

      supported_agent_runtimes = ["python"]
      image_digests = {
        controller  = "sha256:d1ea7b70bb8d97de9f0774d44b598971c944b3ab4e88294b0bb78e59d1a63c15"
        ui          = "sha256:1d5ada8d7f65a6b9ad28232463f9fd670c4c20875baa1c8008aaa1f1f988382e"
        agent       = "sha256:5ee30b4584e8de3266eb3cc11f5c46e8627716339d04d14166c50bda5f0f4182"
        skills_init = "sha256:a1152800fbee8b9143877dcebb981b8a3b450c2c0c3904c8c61e8aa7ce87852a"
      }

      charts = {
        crds = {
          release_name  = "kagent-crds"
          ref           = "oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds@sha256:85174e69eab19e05fcf82dbfda86e8e84c2be97a52c645d60cf1ae51ccbca977"
          version       = "0.9.12"
          values_path   = "helm/vendor/kagent/crds.values.yaml"
          values_sha256 = "753d6253816b5701b653c42311811a2f2399b61e7ae14ad338491c03eb4729cf"
        }
        application = {
          release_name  = "kagent"
          ref           = "oci://ghcr.io/kagent-dev/kagent/helm/kagent@sha256:ec0dacc1a76edbd190a554757c8bdb193ccb0b35deeb35f6d7a7e7ffc76d99fd"
          version       = "0.9.12"
          values_path   = "helm/vendor/kagent/application.values.yaml"
          values_sha256 = "b5f09da13023cf3ff9d1a89025802539d5292ac5f93a194e10fed5d98a691807"
        }
      }

      namespaces = {
        control  = { name = "kagent-system", quota_profile = "testbed-control" }
        workload = { name = "kagent-testbed", quota_profile = "testbed-workload" }
      }

      endpoints = {
        controller = {
          namespace_key = "control"
          pod_selector = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/instance"  = "kagent"
            "app.kubernetes.io/component" = "controller"
          }
        }
        ui = {
          namespace_key = "control"
          pod_selector = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/instance"  = "kagent"
            "app.kubernetes.io/component" = "ui"
          }
        }
        agent_runtime = {
          namespace_key = "workload"
          pod_selector  = { app = "kagent" }
        }
        model_fixture = {
          namespace_key = "workload"
          pod_selector  = { app = "model-fixture" }
        }
      }

      external_sources = {
        edge_tunnel = {
          namespace    = "mcp-tunnel"
          pod_selector = { app = "mcp-tunnel" }
        }
      }

      flows = {
        edge_ui = {
          source_kind     = "external"
          source_key      = "edge_tunnel"
          destination_key = "ui"
          ports           = [{ port = 8080, protocol = "TCP" }]
        }
        ui_controller = {
          source_kind     = "endpoint"
          source_key      = "ui"
          destination_key = "controller"
          ports           = [{ port = 8083, protocol = "TCP" }]
        }
        controller_agent = {
          source_kind     = "endpoint"
          source_key      = "controller"
          destination_key = "agent_runtime"
          ports           = [{ port = 8080, protocol = "TCP" }]
        }
        agent_model = {
          source_kind     = "endpoint"
          source_key      = "agent_runtime"
          destination_key = "model_fixture"
          ports           = [{ port = 11434, protocol = "TCP" }]
        }
      }

      kubernetes_api_egress_from = ["controller"]
      database_bindings = {
        primary = {
          source_endpoint_key   = "controller"
          secret_id_key         = "kagent"
          secret_provider_class = "kagent-database-gcp"
          secret_file           = "database-url"
          port                  = 5432
        }
      }
    }
  }

  # Both phases are intentionally closed. First, a reviewed artifact manifest
  # may open bootstrap_enabled to create Secret Manager containers, namespaces,
  # CRDs and RBAC while native_secret_sync_ready stays false. Only after values
  # are populated and synchronized may a separate review open release_enabled;
  # the retained controller handoff and other readiness attestations remain
  # independent fail-closed gates.
  kagent_substrate_delivery = {
    bootstrap_enabled                  = false
    release_enabled                    = false
    production_eligible                = false
    native_secret_sync_ready           = false
    crd_ownership_ready                = false
    controller_namespace_handoff_ready = false
    external_broker_smoke_ready        = false
  }

  # Creates only infrastructure and an empty Secret Manager container. The
  # dedicated write:packages token is added as an exact external version after
  # an action-time GitHub confirmation; no token byte enters this repository or
  # Terraform state.
  kagent_preview_publisher = {
    enabled                    = true
    evidence_bucket_name       = "yourown-chat-kagent-preview-evidence-europe-west3"
    evidence_retention_seconds = 31536000
    ghcr_secret_id             = "kagent-ghcr-write"
    submitter_members          = []
  }
}
