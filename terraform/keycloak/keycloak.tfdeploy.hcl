# KEYCLOAK deployment `production`: realm, clients and passkey policy only.
# The runtime, database, namespace and network policy are owned by platform-gcp.
# Users are created at runtime and are never Terraform resources.

store "varset" "keycloak" {
  id       = "varset-ypGwPoQ7APKjwVMR"
  category = "terraform"
}

deployment "production" {
  inputs = {
    # Keep the provider component absent until platform-gcp and the public
    # machine-only Admin REST route are deployed. Enable in the follow-up
    # bootstrap configuration after https://yourown.chat/auth is reachable.
    enabled = false

    keycloak_admin_url = "https://yourown.chat/auth"
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
    public_host       = "yourown.chat"
    ios_redirect_uri  = "com.yourown.chat:/oauth/callback"
    smtp_host         = "smtp-relay.gmail.com"
    smtp_from         = "noreply@papou.email"
  }
}

publish_output "issuer" {
  description = "OIDC issuer used by YourOwn.Chat clients and identity-api."
  value       = deployment.production.issuer
}

publish_output "ios_client_id" {
  description = "Public native iOS OIDC client identifier."
  value       = deployment.production.ios_client_id
}

publish_output "terraform_client_ready" {
  description = "Permanent realm-scoped provider client is ready."
  value       = deployment.production.terraform_client_ready
}
