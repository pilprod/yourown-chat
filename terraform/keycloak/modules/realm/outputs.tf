output "realm_name" { value = keycloak_realm.this.realm }
output "auth_broker_client_id" { value = keycloak_openid_client.auth_broker.client_id }
output "terraform_client_ready" {
  value = (
    keycloak_openid_client_service_account_role.terraform_realm_admin.id != "" &&
    keycloak_openid_client_default_scopes.terraform_provider.id != "" &&
    keycloak_generic_role_mapper.terraform_realm_admin_scope.id != ""
  )
}
