# Service-owned private routes consumed only by the existing cloudflare Stack.
locals {
  private_http_routes = {
    kagent = {
      enabled   = false
      namespace = "kagent-system"
      service   = "kagent-ui"
      port      = 8080
    }
  }
}

