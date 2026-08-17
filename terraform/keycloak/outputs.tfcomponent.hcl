output "upstream_issuer" {
  type        = string
  description = "Internal upstream issuer consumed only by the YourOwn.Chat authorization broker."
  value       = var.enabled ? "https://${var.public_host}/realms/${component.realm["production"].realm_name}" : null
}

output "auth_broker_client_id" {
  type        = string
  description = "Public Keycloak client identifier used only by the authorization broker."
  value       = var.enabled ? component.realm["production"].auth_broker_client_id : null
}

output "terraform_client_ready" {
  type        = bool
  description = "True after the permanent realm-scoped provider client and role assignment exist."
  value       = var.enabled ? component.realm["production"].terraform_client_ready : false
}
