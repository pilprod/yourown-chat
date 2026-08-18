output "upstream_issuer" {
  type        = string
  description = "Internal upstream issuer consumed only by the YourOwn.Chat authorization broker."
  value       = null
}

output "auth_broker_client_id" {
  type        = string
  description = "Public Keycloak client identifier used only by the authorization broker."
  value       = null
}

output "terraform_client_ready" {
  type        = bool
  description = "True after the preserved permanent provider client receives its realm-only role without import."
  value       = false
}
