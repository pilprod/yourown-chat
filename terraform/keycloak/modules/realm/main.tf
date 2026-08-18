# The provider client revoked its own realm-admin grant during the first
# destroy attempt. The Keycloak runtime, namespace and database are removed by
# platform-gcp, so the remaining logical objects must only be forgotten here.
# This avoids restoring broad credentials solely to delete data whose backing
# database is being destroyed in the same retirement operation.

removed {
  from = keycloak_realm.this
  lifecycle { destroy = false }
}

removed {
  from = keycloak_required_action.passkey
  lifecycle { destroy = false }
}

removed {
  from = keycloak_user.bootstrap
  lifecycle { destroy = false }
}

removed {
  from = keycloak_openid_client.auth_broker
  lifecycle { destroy = false }
}

removed {
  from = keycloak_openid_client_default_scopes.auth_broker
  lifecycle { destroy = false }
}

removed {
  from = keycloak_openid_client_service_account_role.terraform_realm_admin
  lifecycle { destroy = false }
}

removed {
  from = keycloak_openid_client_default_scopes.terraform_provider
  lifecycle { destroy = false }
}

removed {
  from = keycloak_generic_role_mapper.terraform_realm_admin_scope
  lifecycle { destroy = false }
}
