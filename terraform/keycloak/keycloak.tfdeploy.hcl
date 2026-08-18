# KEYCLOAK deployment `production`: realm, clients, passkey policy and the
# single first-user bootstrap exception.
# The runtime, database, namespace and network policy are owned by platform-gcp.
# All users after pilprod are created through the application runtime.

locals {
  gcp_wif_audience = "//iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"
  gcp_apply_sa     = "terraform-apply@yourown-chat.iam.gserviceaccount.com"
  gcp_project      = "yourown-chat"
  gcp_region       = "europe-west3"
}

identity_token "gcp" {
  audience = ["https://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/providers/hcp-terraform"]
}

upstream_input "platform" {
  type   = "stack"
  source = "app.terraform.io/papou-work/yourown-chat/platform-gcp"
}

store "varset" "keycloak" {
  id       = "varset-ypGwPoQ7APKjwVMR"
  category = "terraform"
}

deployment "production" {
  inputs = {
    identity_token        = identity_token.gcp.jwt
    audience              = local.gcp_wif_audience
    service_account_email = local.gcp_apply_sa
    project_id            = local.gcp_project
    region                = local.gcp_region

    # Phase 1 keeps provider evaluation inert while platform-gcp creates the
    # runtime, DNS and machine-only Admin REST route. A reviewed follow-up
    # flips only this gate to true after those dependencies are applied.
    enabled = true

    keycloak_admin_url = "https://auth.yourown.chat"
    keycloak_version   = "26.7.1"

    # hashicorp/terraform#37822 prevents repeating the write-only secret across
    # the component boundary. Importing the permanent client is also forbidden
    # because the provider read path returns its secret into state. Only the
    # non-secret object IDs are used to assign the target-realm role. The
    # provider now authenticates only as that realm-scoped client.
    terraform_client_id             = "terraform-provider"
    terraform_client_internal_id    = "5ffd1da1-be6a-4108-965d-1d1d2d9fd78c"
    terraform_service_account_user_id = "5b84a940-a964-4c1e-a549-74767f78341d"
    realm_management_client_id      = "5b66df6c-f179-4d0b-8b63-c0ee329ea164"
    realm_admin_role_id             = "130319ba-1117-404d-8a76-92a09c7d6f05"
    terraform_client_secret          = store.varset.keycloak.keycloak_terraform_client_secret
    terraform_client_secret_version  = "1"

    realm_name        = "yourown-chat"
    public_host       = "auth.yourown.chat"
    broker_redirect_uris = [
      "https://auth.yourown.chat/complete",
      "https://auth.yourown.chat/callback",
    ]
    smtp_host         = "smtp-relay.gmail.com"
    smtp_from         = "noreply@papou.email"

    bootstrap_user_username           = "pilprod"
    bootstrap_user_password_secret_id = upstream_input.platform.keycloak_bootstrap_user_password_secret_id
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
  description = "Permanent realm-scoped provider client readiness."
  value       = deployment.production.terraform_client_ready
}
