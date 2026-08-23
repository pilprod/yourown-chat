# Private service catalog inputs. Values live only in this private repository's
# deployment file and in the Stack's last-applied outputs; the public platform
# Stacks consume them through upstream_input and never define them.
variable "github_connection_name" {
  type        = string
  description = "Name of the existing Cloud Build 2nd-gen GitHub connection every source repository is linked to."
}

variable "source_repositories" {
  type = map(object({
    name       = string
    remote_uri = string
  }))
  description = "Source repositories keyed by role (deploy, mattermost, web, server_source, backend, agents, mcp, rtcd). `name` is the Cloud Build 2nd-gen repository resource name; `remote_uri` is the HTTPS clone URL."
}

variable "catalog_revision" {
  type        = string
  description = "Human-readable revision marker of the catalog contents. Changing it forces a changed apply so the published values propagate to downstream Stacks."
}
