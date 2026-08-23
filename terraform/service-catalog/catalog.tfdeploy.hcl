# SERVICE-CATALOG deployment `eu`: the private catalog of repository
# connections consumed by the public app-gcp Stack (upstream_input.catalog).
# This Stack creates no cloud resources; its last-applied outputs are the
# contract. Apply order: service-catalog -> app-gcp.

deployment "eu" {
  inputs = {
    # Bump on every catalog change; a changed apply is what pushes the
    # published values to downstream Stacks (an unchanged apply does not).
    catalog_revision = "2026-08-23.3"

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

    # Closed, production-ineligible stock baseline. Every artifact and values
    # digest is copied from the product-owned lock at the exact commit below.
    kagent_testbed = {
      enabled        = true
      candidate_tag  = "testbed-20260823-1"
      product_commit = "8891efbd6b560a182e69add46d557f3236072f90"

      chart_repository              = "oci://ghcr.io/kagent-dev/kagent/helm"
      chart_version                 = "0.9.12"
      source_commit                 = "b45990582595acea5f6e765b86a10b251c50d5c9"
      application_chart_oci_digest = "sha256:ec0dacc1a76edbd190a554757c8bdb193ccb0b35deeb35f6d7a7e7ffc76d99fd"
      crd_chart_oci_digest          = "sha256:85174e69eab19e05fcf82dbfda86e8e84c2be97a52c645d60cf1ae51ccbca977"
      application_values_sha256     = "de2e5f3fc6e6bdc7f1f93eb2a6453213ff800187071267514606f6bdd595fce2"
      crd_values_sha256             = "753d6253816b5701b653c42311811a2f2399b61e7ae14ad338491c03eb4729cf"

      namespace          = "kagent-system"
      workload_namespace = "kagent-testbed"
      ui_hostname        = "kagent.yourown.chat"
      ui_service         = "http://kagent-ui.kagent-system.svc.cluster.local:8080"
    }

    # Private edge assignments stay outside the public platform source. The
    # Cloudflare Stack turns each entry into Tunnel routing, DNS and Access.
    private_upstreams = {
      kagent = "http://kagent-ui.kagent-system.svc.cluster.local:8080"
    }
  }
}

# Cross-stack contract: consumed as upstream_input.catalog.<name> in app-gcp.
publish_output "github_connection_name" {
  description = "Cloud Build 2nd-gen GitHub connection name shared by every source repository link."
  value       = deployment.eu.github_connection_name
}

publish_output "source_repositories" {
  description = "Source repositories keyed by role (deploy, mattermost, web, server_source, backend, agents, mcp, rtcd)."
  value       = deployment.eu.source_repositories
}

publish_output "catalog_revision" {
  description = "Revision marker of the published catalog (changes on every catalog release)."
  value       = deployment.eu.catalog_revision
}

publish_output "kagent_testbed" {
  description = "Pinned, product-owned, production-ineligible stock Kagent testbed release."
  value       = deployment.eu.kagent_testbed
}

publish_output "private_upstreams" {
  description = "Private hostname labels and in-cluster ClusterIP origins consumed by the Cloudflare Access/Tunnel Stack."
  value       = deployment.eu.private_upstreams
}
