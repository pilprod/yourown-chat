resource "keycloak_realm" "this" {
  realm                         = var.realm_name
  display_name                  = "YourOwn.Chat"
  enabled                       = true
  terraform_deletion_protection = true

  ssl_required                  = "external"
  registration_allowed         = true
  # Keep the stable platform username independent from an email address. Email
  # login remains enabled below, so users with an address can use either form.
  registration_email_as_username = false
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

# This is the sole human-user bootstrap exception. Secret Manager is the
# source of the random credential, Keycloak accepts it only for creation, and
# temporary=true forces replacement on the first successful sign-in. The
# default passkey required action above then enrolls the user's passkey.
data "google_secret_manager_secret_version" "bootstrap_user_password" {
  project = var.project_id
  secret  = var.bootstrap_user_password_secret_id
  version = "latest"
}

resource "keycloak_user" "bootstrap" {
  realm_id = keycloak_realm.this.id
  username = var.bootstrap_user_username
  enabled  = true

  # Apply these once when the user is created. Keycloak removes each action
  # after the user completes it; Terraform must not add it back later.
  required_actions = [
    "UPDATE_PASSWORD",
    keycloak_required_action.passkey.alias,
  ]

  initial_password {
    value     = data.google_secret_manager_secret_version.bootstrap_user_password.secret_data
    temporary = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      attributes,
      email,
      email_verified,
      federated_identity,
      first_name,
      last_name,
      required_actions,
    ]
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

  valid_redirect_uris             = var.broker_redirect_uris
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

# The permanent client was created only through this provider's write-only
# secret field during bootstrap. Import is deliberately forbidden: the
# provider's read path returns the client secret and would persist it in Stack
# state. The non-secret Keycloak object IDs are pinned for the recovery phase;
# a rebuilt realm must repeat the reviewed provider-only bootstrap.
resource "keycloak_openid_client_service_account_role" "terraform_realm_admin" {
  realm_id                = keycloak_realm.this.id
  service_account_user_id = var.terraform_service_account_user_id
  client_id               = var.realm_management_client_id
  role                    = "realm-admin"
}

# Service-account role mappings are not included when full scope is disabled
# unless the built-in roles client scope is explicitly attached. Keep only
# that scope: the provider client does not need profile, email or web origins.
resource "keycloak_openid_client_default_scopes" "terraform_provider" {
  realm_id      = keycloak_realm.this.id
  client_id     = var.terraform_client_internal_id
  default_scopes = ["roles"]
}

# With full_scope_allowed=false, attaching the built-in roles scope is not
# enough: Keycloak also requires an explicit role scope mapping before it will
# place realm-management roles in the service-account access token. Keep the
# already-created role UUID stable just like the adjacent client UUIDs; reading
# it through a data source during a realm update makes Terraform unnecessarily
# replace this mapper because the refreshed ID is unknown during planning.
resource "keycloak_generic_role_mapper" "terraform_realm_admin_scope" {
  realm_id  = keycloak_realm.this.id
  client_id = var.terraform_client_internal_id
  role_id   = var.realm_admin_role_id
}
