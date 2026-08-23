# SERVICE-CATALOG deployment `eu`: the private catalog of repository
# connections consumed by the public app-gcp Stack (upstream_input.catalog).
# This Stack creates no cloud resources; its last-applied outputs are the
# contract. Apply order: service-catalog -> app-gcp.

deployment "eu" {
  inputs = {
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
      # Current (legacy) RTCD input kept verbatim so the first app-gcp plan is
      # a no-op. Switching to pilprod/rtcd is a catalog-only change owned by the
      # RTCD consolidation task (it recreates the Cloud Build link/trigger).
      rtcd = {
        name       = "yourown-chat-rtcd"
        remote_uri = "https://github.com/pilprod/yourown-chat-rtcd.git"
      }
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
