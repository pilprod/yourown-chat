output "realm_name" { value = keycloak_realm.this.realm }
output "ios_client_id" { value = keycloak_openid_client.ios.client_id }
output "terraform_client_ready" {
  value = keycloak_openid_client_service_account_role.terraform_realm_admin.id != ""
}
