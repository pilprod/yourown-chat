resource "keycloak_realm" "this" {
  realm                         = var.realm_name
  display_name                  = "YourOwn.Chat"
  enabled                       = true
  terraform_deletion_protection = true

  ssl_required                  = "external"
  registration_allowed         = true
  registration_email_as_username = true
  login_with_email_allowed     = true
  duplicate_emails_allowed     = false
  edit_username_allowed        = false
  reset_password_allowed       = true
  remember_me                  = true
  verify_email                 = true

  password_policy = "length(12) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername"

  access_token_lifespan         = "5m"
  sso_session_idle_timeout      = "30m"
  sso_session_max_lifespan      = "10h"
  offline_session_idle_timeout  = "720h"

  smtp_server {
    host              = var.smtp_host
    port              = 587
    from              = var.smtp_from
    from_display_name = "YourOwn.Chat"
    starttls           = true
  }

  security_defenses {
    headers {
      x_frame_options           = "DENY"
      content_security_policy   = "frame-src 'self'; frame-ancestors 'self'; object-src 'none';"
      x_content_type_options    = "nosniff"
      x_robots_tag              = "none"
      strict_transport_security = "max-age=31536000; includeSubDomains"
    }
    brute_force_detection {
      permanent_lockout                  = false
      max_login_failures                 = 5
      wait_increment_seconds             = 60
      quick_login_check_milli_seconds    = 1000
      minimum_quick_login_wait_seconds   = 60
      max_failure_wait_seconds           = 900
      failure_reset_time_seconds         = 43200
    }
  }

  web_authn_policy {
    relying_party_entity_name      = "YourOwn.Chat"
    relying_party_id               = var.public_host
    signature_algorithms           = ["ES256", "RS256"]
    user_verification_requirement  = "required"
    avoid_same_authenticator_register = true
  }

  web_authn_passwordless_policy {
    relying_party_entity_name       = "YourOwn.Chat"
    relying_party_id                = var.public_host
    signature_algorithms            = ["ES256", "RS256"]
    discoverable_credential         = "required"
    user_verification_requirement   = "required"
    avoid_same_authenticator_register = true
    passwordless_passkeys_enabled   = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "keycloak_required_action" "passkey" {
  realm_id      = keycloak_realm.this.id
  alias         = "webauthn-register-passwordless"
  name          = "Register a passkey"
  enabled       = true
  default_action = true
  priority      = 10
  config = {
    max_auth_age = "300"
  }
}

resource "keycloak_openid_client" "auth_broker" {
  realm_id  = keycloak_realm.this.id
  client_id = "yourown-chat-auth-broker"
  name      = "YourOwn.Chat authorization broker"
  enabled   = true

  access_type                  = "PUBLIC"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false
  pkce_code_challenge_method   = "S256"
  use_refresh_tokens           = false
  full_scope_allowed           = false
  # The broker callback accepts only the minimum form_post payload. Removing
  # compatibility fields avoids both URL leakage and parser ambiguity.
  exclude_session_state_from_auth_response = true
  exclude_issuer_from_auth_response        = true

  valid_redirect_uris             = [var.broker_redirect_uri]
  valid_post_logout_redirect_uris = []
  web_origins                     = []
}

resource "keycloak_openid_client_default_scopes" "auth_broker" {
  realm_id  = keycloak_realm.this.id
  client_id = keycloak_openid_client.auth_broker.id
  default_scopes = [
    "email",
    "profile",
    "roles",
    "web-origins",
  ]
}

# The write-only secret reached Keycloak before the first Stack apply failed,
# leaving this otherwise valid client tainted in Terraform state. Forget only
# the state record in phase one; a reviewed follow-up imports the same remote
# client at a clean address and completes its realm-only role assignment.
removed {
  from = keycloak_openid_client.terraform_provider

  lifecycle {
    destroy = false
  }
}
