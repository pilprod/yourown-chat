output "issuer" {
  type        = string
  description = "Stable issuer consumed by YourOwn.Chat clients and identity-api."
  value       = var.enabled ? "https://${var.public_host}/realms/${component.realm["production"].realm_name}" : null
}

output "ios_client_id" {
  type        = string
  description = "Public iOS OIDC client identifier."
  value       = var.enabled ? component.realm["production"].ios_client_id : null
}

output "terraform_client_ready" {
  type        = bool
  description = "True after the permanent realm-scoped provider client and role assignment exist."
  value       = var.enabled ? component.realm["production"].terraform_client_ready : false
}
