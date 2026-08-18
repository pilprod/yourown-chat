# The old provider client revoked its own realm-admin grant during the first
# destroy attempt. Forget the component state without contacting Keycloak;
# platform-gcp destroys the backing database and namespace separately.
removed {
  from   = component.realm["production"]
  source = "./modules/realm"

  lifecycle {
    destroy = false
  }
}
