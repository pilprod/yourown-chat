# ---------------------------------------------------------------------------
# Build-owned CMEK key. This key is created and owned by the BUILD stack so the
# build stack does NOT depend on the platform stack's KMS key (no platform->build
# ordering coupling). Its sole job is to wrap the DEK of the GitHub PAT secret in
# Secret Manager -- the token the Cloud Build 2nd-gen connection uses to reach
# GitHub. The container registry is public and is deliberately NOT CMEK-encrypted.
#
# The keyring is named `${location}-build-keyring` so it never collides with the
# platform stack's regional keyring (`${location}-keyring`) in the same project.
#
# Cost: a key ring is free; a SOFTWARE key version is ~$0.06/mo. This single
# low-value key is SOFTWARE by default (a PAT secret does not need HSM custody).
#
# Teardown note: Cloud KMS key rings and keys CANNOT be deleted from GCP -- only
# key VERSIONS can be scheduled for destruction. On `terraform destroy` the
# provider drops them from state (they persist in the project), so a later
# re-apply with the SAME names is a no-op rather than a fresh create. Names are
# deliberately stable (no random suffix).
# ---------------------------------------------------------------------------

locals {
  key_ring_name   = "${var.location}-build-keyring"
  crypto_key_name = var.key_name
}

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = local.key_ring_name
  location = var.location
}

resource "google_kms_crypto_key" "this" {
  name     = local.crypto_key_name
  key_ring = google_kms_key_ring.this.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = var.rotation_period

  labels = var.labels

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.protection_level
  }
}

# Force-create the Secret Manager per-project service agent so the IAM grant
# below never races a not-yet-existent principal, then let it wrap/unwrap the
# github-pat secret's DEK with this key.
resource "google_project_service_identity" "secretmanager" {
  provider = google-beta

  project = var.project_id
  service = "secretmanager.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "secretmanager" {
  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secretmanager.email}"
}
