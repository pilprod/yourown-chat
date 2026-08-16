output "issuer" {
  type        = string
  description = "Stable issuer consumed by YourOwn.Chat clients and identity-api."
  value       = "https://${var.public_host}/auth/realms/${component.realm.realm_name}"
}

output "ios_client_id" {
  type        = string
  description = "Public iOS OIDC client identifier."
  value       = component.realm.ios_client_id
}

output "terraform_client_ready" {
  type        = bool
  description = "True after the permanent realm-scoped provider client and role assignment exist."
  value       = component.realm.terraform_client_ready
}
