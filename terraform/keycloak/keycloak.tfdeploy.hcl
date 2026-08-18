# KEYCLOAK deployment `production`: realm, clients and passkey policy only.
# The runtime, database, namespace and network policy are owned by platform-gcp.
# Users are created at runtime and are never Terraform resources.

store "varset" "keycloak" {
  id       = "varset-ypGwPoQ7APKjwVMR"
  category = "terraform"
}

deployment "production" {
  inputs = {
    # Phase 1 keeps provider evaluation inert while platform-gcp creates the
    # runtime, DNS and machine-only Admin REST route. A reviewed follow-up
    # flips only this gate to true after those dependencies are applied.
    enabled = true

    keycloak_admin_url = "https://auth.yourown.chat"
    keycloak_version   = "26.7.1"

    # One-time first apply. After terraform_client_ready=true, switch this to
    # false and remove the temporary bootstrap service account from master.
    bootstrap_mode                = true
    bootstrap_admin_client_id     = "bootstrap-admin"
    bootstrap_admin_client_secret = store.varset.keycloak.keycloak_bootstrap_admin_client_secret

    terraform_client_id             = "terraform-provider"
    terraform_client_secret          = store.varset.keycloak.keycloak_terraform_client_secret
    terraform_client_secret_version  = "1"

    realm_name        = "yourown-chat"
    public_host       = "auth.yourown.chat"
    broker_redirect_uri = "https://auth.yourown.chat/callback"
    smtp_host         = "smtp-relay.gmail.com"
    smtp_from         = "noreply@papou.email"
  }
}

publish_output "upstream_issuer" {
  description = "Keycloak issuer used only by the YourOwn.Chat authorization broker."
  value       = deployment.production.upstream_issuer
}

publish_output "auth_broker_client_id" {
  description = "Public Keycloak client identifier used only by the authorization broker."
  value       = deployment.production.auth_broker_client_id
}

publish_output "terraform_client_ready" {
  description = "Permanent realm-scoped provider client is ready."
  value       = deployment.production.terraform_client_ready
}
