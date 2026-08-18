variable "identity_token" {
  type        = string
  ephemeral   = true
  description = "Short-lived HCP Terraform OIDC token used for keyless Google Cloud access."
}

variable "audience" {
  type        = string
  description = "Full Google Cloud Workload Identity Federation provider resource name."
}

variable "service_account_email" {
  type        = string
  description = "Least-privilege Google Cloud apply service account impersonated through WIF."
}

variable "project_id" {
  type        = string
  description = "Google Cloud project containing the bootstrap password secret."
}

variable "region" {
  type        = string
  description = "Primary Google Cloud region."
}

variable "bootstrap_user_username" {
  type        = string
  description = "The only human user created by Terraform, for the first platform sign-in."
  default     = "pilprod"

  validation {
    condition     = var.bootstrap_user_username == "pilprod"
    error_message = "Only the reviewed first user pilprod may be bootstrapped through Terraform."
  }
}

variable "bootstrap_user_password_secret_id" {
  type        = string
  description = "Secret Manager secret ID containing the one-time bootstrap password."

  validation {
    condition     = var.bootstrap_user_password_secret_id == "keycloak-pilprod-initial-password"
    error_message = "The bootstrap password must come from the dedicated pilprod secret."
  }
}

variable "keycloak_admin_url" {
  type        = string
  description = "HTTPS Keycloak endpoint used by the Terraform provider. The public Admin Console is not routed."

  validation {
    condition     = var.keycloak_admin_url == "https://auth.yourown.chat"
    error_message = "keycloak_admin_url must be the canonical https://auth.yourown.chat origin."
  }
}

variable "enabled" {
  type        = bool
  description = "Bootstrap gate. Enable only after the Keycloak runtime and provider ingress are reachable."
  default     = false
}

variable "keycloak_version" {
  type        = string
  description = "Exact Keycloak runtime version. The provider uses this because the realm-scoped client cannot read global server information."
}

variable "terraform_client_id" {
  type        = string
  description = "Permanent realm-scoped machine client used by this provider after bootstrap."
  default     = "terraform-provider"
}

variable "terraform_service_account_user_id" {
  type        = string
  description = "Non-secret Keycloak service-account user UUID of the preserved Terraform provider client."
}

variable "terraform_client_internal_id" {
  type        = string
  description = "Non-secret internal UUID of the preserved Terraform provider client."
}

variable "realm_management_client_id" {
  type        = string
  description = "Non-secret internal UUID of the realm-management client in the target realm."
}

variable "realm_admin_role_id" {
  type        = string
  description = "Non-secret stable UUID of the existing realm-management realm-admin role."
}

variable "terraform_client_secret" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Write-only permanent provider client secret from a private HCP variable set."

  validation {
    condition     = length(var.terraform_client_secret) >= 32
    error_message = "terraform_client_secret must contain at least 32 characters."
  }
}

variable "terraform_client_secret_version" {
  type        = string
  description = "Non-secret rotation marker for the write-only provider client secret."
}

variable "realm_name" {
  type        = string
  description = "Stable product realm name."
  default     = "yourown-chat"
}

variable "public_host" {
  type        = string
  description = "Public RP host used for WebAuthn/passkeys."
  default     = "auth.yourown.chat"

  validation {
    condition     = var.public_host == "auth.yourown.chat"
    error_message = "public_host must be the canonical auth.yourown.chat passkey RP host."
  }
}

variable "broker_redirect_uris" {
  type        = set(string)
  description = "Exact current and temporary compatibility callbacks for the public authorization facade. Wildcards are forbidden."
  default = [
    "https://auth.yourown.chat/complete",
    "https://auth.yourown.chat/callback",
  ]

  validation {
    condition = (
      length(var.broker_redirect_uris) == 2 &&
      contains(var.broker_redirect_uris, "https://auth.yourown.chat/complete") &&
      contains(var.broker_redirect_uris, "https://auth.yourown.chat/callback")
    )
    error_message = "The production broker accepts only /complete and the temporary /callback compatibility path."
  }
}

variable "smtp_host" {
  type        = string
  description = "SMTP relay reached through the platform's allowlisted Cloud NAT address."
  default     = "smtp-relay.gmail.com"
}

variable "smtp_from" {
  type        = string
  description = "Verified sender used for email verification and recovery."
  default     = "noreply@papou.email"
}
