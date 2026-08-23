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
      name       = "yourown-chat-kagent"
      remote_uri = "https://github.com/pilprod/yourown-chat-kagent.git"
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
      provisioned         = true
      application_enabled = true
      deployment_class    = "testbed"
      production_eligible = false
      candidate_tag       = "testbed-20260823-1"
      product_commit      = "1d15fe74a70726b6a9862b3a6859e69d0491b03d"
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
          values_base64 = "IyBUaGUgTTAgYmFzZWxpbmUgdXNlcyBvbmx5IHRoZSBjb3JlIGthZ2VudCBDUkRzLiBLTUNQIGFuZCBBZ2VudCBTdWJzdHJhdGUgYXJlCiMgcXVhbGlmaWVkIHNlcGFyYXRlbHkgYW5kIG11c3Qgbm90IGFycml2ZSBhcyB0cmFuc2l0aXZlIENSRCBkZXBlbmRlbmNpZXMuCmttY3A6CiAgZW5hYmxlZDogZmFsc2UKCnN1YnN0cmF0ZToKICBlbmFibGVkOiBmYWxzZQo="
          values_sha256 = "753d6253816b5701b653c42311811a2f2399b61e7ae14ad338491c03eb4729cf"
        }
        application = {
          release_name  = "kagent"
          ref           = "oci://ghcr.io/kagent-dev/kagent/helm/kagent@sha256:ec0dacc1a76edbd190a554757c8bdb193ccb0b35deeb35f6d7a7e7ffc76d99fd"
          version       = "0.9.12"
          values_base64 = "IyBQcm9kdWN0LW93bmVkIHZhbHVlcyBmb3IgdGhlIHN0b2NrLCBzaW5nbGUtdXNlciBNMCB0ZXN0YmVkLiBUaGUgcHVibGljCiMgcGxhdGZvcm0gYWRhcHRlciBtaXJyb3JzIHRoaXMgY2xvc2VkIHByb2ZpbGUgYW5kIHZlcmlmaWVzIGl0cyByZWxlYXNlIGRpZ2VzdC4KZnVsbG5hbWVPdmVycmlkZToga2FnZW50Cm5hbWVzcGFjZU92ZXJyaWRlOiBrYWdlbnQtc3lzdGVtCgpyZWdpc3RyeTogY3Iua2FnZW50LmRldgojIEtlZXAgdGhlIGdsb2JhbCB0YWcgZW1wdHkgc28gZWFjaCBpbmRlcGVuZGVudGx5IGJ1aWx0IGltYWdlIGNhbiBiZSBwaW5uZWQgdG8KIyBpdHMgb3duIGltbXV0YWJsZSBPQ0kgbWFuaWZlc3QgZGlnZXN0IGJlbG93Lgp0YWc6ICIiCmltYWdlUHVsbFBvbGljeTogSWZOb3RQcmVzZW50CgpsYWJlbHM6CiAgYXBwLmt1YmVybmV0ZXMuaW8vcGFydC1vZjogazhzLWFnZW50cy1wbGF0Zm9ybQogIHBsYXRmb3JtLnlvdXJvd24uY2hhdC9yZWxlYXNlLWNoYW5uZWw6IHRlc3RiZWQKCnJiYWM6CiAgbmFtZXNwYWNlczoKICAgIC0ga2FnZW50LXN5c3RlbQogICAgLSBrYWdlbnQtdGVzdGJlZAoKY29udHJvbGxlcjoKICByZXBsaWNhczogMQogIGxvZ2xldmVsOiBpbmZvCiAgaW1hZ2U6CiAgICB0YWc6ICIwLjkuMTJAc2hhMjU2OmQxZWE3YjcwYmI4ZDk3ZGU5ZjA3NzRkNDRiNTk4OTcxYzk0NGIzYWI0ZTg4Mjk0YjBiYjc4ZTU5ZDFhNjNjMTUiCiAgIyBNMCBxdWFsaWZpZXMgb25seSB0aGUgUHl0aG9uIGFnZW50IHJ1bnRpbWUuIFRoZSBjaGFydCBkZXJpdmVzIGEgZGlmZmVyZW50CiAgIyByZXBvc2l0b3J5IGZvciBHbyBhZ2VudHMgd2hpbGUgcmV1c2luZyB0aGlzIHRhZywgc28gR28gcmVtYWlucyBkaXNhYmxlZAogICMgdW50aWwga2FnZW50IHB1Ymxpc2hlcyBhbmQgd2UgbG9jayBhIG1hdGNoaW5nIEdvIHJ1bnRpbWUgaW1hZ2UuCiAgYWdlbnRJbWFnZToKICAgIHRhZzogIjAuOS4xMkBzaGEyNTY6NWVlMzBiNDU4NGU4ZGUzMjY2ZWIzY2MxMWY1YzQ2ZTg2Mjc3MTYzMzlkMDRkMTQxNjZjNTBiZGE1ZjBmNDE4MiIKICBza2lsbHNJbml0SW1hZ2U6CiAgICB0YWc6ICIwLjkuMTJAc2hhMjU2OmExMTUyODAwZmJlZThiOTE0Mzg3N2RjZWJiOTgxYjhhM2I0NTBjMmMwYzM5MDRjOGM2MWU4YWE3Y2U4Nzg1MmEiCiAgdm9sdW1lczoKICAgIC0gbmFtZTogZGF0YWJhc2UtdXJsCiAgICAgIGNzaToKICAgICAgICBkcml2ZXI6IHNlY3JldHMtc3RvcmUtZ2tlLmNzaS5rOHMuaW8KICAgICAgICByZWFkT25seTogdHJ1ZQogICAgICAgIHZvbHVtZUF0dHJpYnV0ZXM6CiAgICAgICAgICBzZWNyZXRQcm92aWRlckNsYXNzOiBrYWdlbnQtZGF0YWJhc2UtZ2NwCiAgdm9sdW1lTW91bnRzOgogICAgLSBuYW1lOiBkYXRhYmFzZS11cmwKICAgICAgbW91bnRQYXRoOiAvdmFyL3J1bi9zZWNyZXRzL2thZ2VudC1kYXRhYmFzZQogICAgICByZWFkT25seTogdHJ1ZQogIHdhdGNoTmFtZXNwYWNlczoKICAgIC0ga2FnZW50LXN5c3RlbQogICAgLSBrYWdlbnQtdGVzdGJlZAogICMgdjAuOS4xMiBpcyBub3QgYSBtdWx0aS11c2VyIGF1dGhvcml6YXRpb24gYm91bmRhcnkuIENsb3VkZmxhcmUgQWNjZXNzIGFuZAogICMgdGhlIHBsYXRmb3JtIE5ldHdvcmtQb2xpY2llcyBpc29sYXRlIHRoaXMgZXhwbGljaXRseSBzaW5nbGUtdXNlciB0ZXN0YmVkLgogIGF1dGg6CiAgICBtb2RlOiB1bnNlY3VyZQogIHN1YnN0cmF0ZToKICAgIGVuYWJsZWQ6IGZhbHNlCgp1aToKICByZXBsaWNhczogMQogIGltYWdlOgogICAgdGFnOiAiMC45LjEyQHNoYTI1NjoxZDVhZGE4ZDdmNjVhNmI5YWQyODIzMjQ2M2Y5ZmQ2NzBjNGMyMDg3NWJhYTFjODAwOGFhYTFmMWY5ODgzODJlIgogIHNlcnZpY2U6CiAgICB0eXBlOiBDbHVzdGVySVAKICAgIHBvcnRzOgogICAgICBwb3J0OiA4MDgwCiAgICAgIHRhcmdldFBvcnQ6IDgwODAKCmRhdGFiYXNlOgogIHBvc3RncmVzOgogICAgIyBUaGUgcGxhdGZvcm0gY3JlYXRlcyBhIGRlZGljYXRlZCBkYXRhYmFzZS91c2VyIGluIHRoZSBleGlzdGluZyBwcm90ZWN0ZWQKICAgICMgQ2xvdWQgU1FMIGluc3RhbmNlLiBUaGUgcmVhZHktdG8tdXNlIFVSSSBpcyBtb3VudGVkIGZyb20gU2VjcmV0IE1hbmFnZXIuCiAgICB1cmxGaWxlOiAvdmFyL3J1bi9zZWNyZXRzL2thZ2VudC1kYXRhYmFzZS9kYXRhYmFzZS11cmwKICAgIHZlY3RvckVuYWJsZWQ6IGZhbHNlCiAgICBidW5kbGVkOgogICAgICBlbmFibGVkOiBmYWxzZQoKcHJvdmlkZXJzOgogICMgTTAgbXVzdCBzdGFydCB3aXRob3V0IGEgbW9kZWwtcHJvdmlkZXIgc2VjcmV0LiBTeXN0ZW0gRTJFIHN1cHBsaWVzIGEKICAjIGRldGVybWluaXN0aWMgZml4dHVyZSBhdCB0aGlzIHByaXZhdGUgYWRkcmVzczsgcmVhbCBwcm92aWRlcnMgYXJlIG9wdC1pbi4KICBkZWZhdWx0OiBvbGxhbWEKICBvbGxhbWE6CiAgICBwcm92aWRlcjogT2xsYW1hCiAgICBtb2RlbDogZml4dHVyZS1tb2RlbAogICAgY29uZmlnOgogICAgICBob3N0OiBodHRwOi8vbW9kZWwtZml4dHVyZS5rYWdlbnQtdGVzdGJlZC5zdmMuY2x1c3Rlci5sb2NhbDoxMTQzNAoKa21jcDoKICBlbmFibGVkOiBmYWxzZQoKc3Vic3RyYXRlOgogIGVuYWJsZWQ6IGZhbHNlCgpzdWJzdHJhdGVXb3JrZXJQb29sOgogIGNyZWF0ZTogZmFsc2UKCmthZ2VudC10b29sczoKICBlbmFibGVkOiBmYWxzZQoKZ3JhZmFuYS1tY3A6CiAgZW5hYmxlZDogZmFsc2UKCnF1ZXJ5ZG9jOgogIGVuYWJsZWQ6IGZhbHNlCgpvYXV0aDItcHJveHk6CiAgIyBIdW1hbiBhdXRoZW50aWNhdGlvbiBpcyBwcm92aWRlZCBieSB0aGUgZXhpc3RpbmcgQ2xvdWRmbGFyZSBBY2Nlc3MgZWRnZS4KICAjIERvIG5vdCBkZXBsb3kgYSBzZWNvbmQsIGluZGVwZW5kZW50bHkgY29uZmlndXJlZCBpZGVudGl0eSBwcm94eSBpbiBNMC4KICBlbmFibGVkOiBmYWxzZQoKazhzLWFnZW50OgogIGVuYWJsZWQ6IGZhbHNlCgprZ2F0ZXdheS1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQoKaXN0aW8tYWdlbnQ6CiAgZW5hYmxlZDogZmFsc2UKCnByb21xbC1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQoKb2JzZXJ2YWJpbGl0eS1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQoKYXJnby1yb2xsb3V0cy1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQoKaGVsbS1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQoKY2lsaXVtLXBvbGljeS1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQoKY2lsaXVtLW1hbmFnZXItYWdlbnQ6CiAgZW5hYmxlZDogZmFsc2UKCmNpbGl1bS1kZWJ1Zy1hZ2VudDoKICBlbmFibGVkOiBmYWxzZQo="
          values_sha256 = "c9986976eea83ae60288ae12f44fa315f7ba1b61b5b9d7bfe88dd1b5e80ea518"
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
}

