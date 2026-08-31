# Service-owned private routes consumed only by the existing cloudflare Stack.
locals {
  private_http_routes = {
    # Cloud Deploy exposes the independent development control plane before
    # the approval gate.
    # The nested key intentionally renders as dev.kagent.yourown.chat.
    "dev.kagent" = {
      enabled   = true
      namespace = "kagent-dev"
      service   = "kagent-ui"
      port      = 8080
    }

    # The approved production control plane stays isolated from subsequent
    # development upgrades. Both routes use the Access-protected browser edge.
    kagent = {
      enabled   = true
      namespace = "kagent-system"
      service   = "kagent-ui"
      port      = 8080
    }
  }
}
