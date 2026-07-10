# ---------------------------------------------------------------------------
# One shared CMEK key for the whole platform. A single symmetric key wraps the
# data-encryption keys (DEKs) of every at-rest store that supports CMEK:
#   - Cloud SQL (Postgres)     -- platform stack (this stack)
#   - Cloud Storage (filestore)-- platform stack (this stack)
#   - Artifact Registry (Docker) -- build stack, which references THIS key by its
#                                   deterministic resource path (see outputs).
# The key is regional (must match every consumer's region) and lives in the
# platform stack because that stack is applied first and enables the KMS API.
#
# Cost: a KMS key ring is free; you pay per active key version (~$1.00/mo for an
# HSM version, ~$0.06 for SOFTWARE) plus negligible wrap/unwrap operations. One
# shared key = one active version, so the whole platform's CMEK is ~$1/mo.
#
# Teardown note: Cloud KMS key rings and keys CANNOT be deleted from GCP -- only
# key VERSIONS can be scheduled for destruction. On `terraform destroy` the
# provider drops them from state (they persist in the project), so a later
# re-apply with the SAME names is a no-op import-or-conflict rather than a fresh
# create. Names are deliberately stable (no random suffix) because the build
# stack references the key by its deterministic path.
# ---------------------------------------------------------------------------

locals {
  key_ring_name   = "${var.name_prefix}-keyring"
  crypto_key_name = "${var.name_prefix}-cmek"
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

  # Rotation applies to the primary version used for new encryptions; existing
  # data is transparently re-wrapped on access. Old versions stay enabled for
  # decrypt until explicitly destroyed.
  rotation_period = var.rotation_period

  labels = var.labels

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = var.protection_level
  }
}

# --- Service agents that wrap/unwrap DEKs with the shared key ----------------
# Force-create each consuming service's per-project agent (equivalent to
# `gcloud beta services identity create --service=<api>`) so the IAM grants below
# never race a not-yet-existent principal. Cloud Storage exposes its agent via a
# GA data source; Cloud SQL and Artifact Registry need the beta identity resource.
resource "google_project_service_identity" "cloudsql" {
  count    = var.grant_cloudsql ? 1 : 0
  provider = google-beta

  project = var.project_id
  service = "sqladmin.googleapis.com"
}

resource "google_project_service_identity" "artifact_registry" {
  count    = var.grant_artifact_registry ? 1 : 0
  provider = google-beta

  project = var.project_id
  service = "artifactregistry.googleapis.com"
}

data "google_storage_project_service_account" "gcs" {
  count   = var.grant_storage ? 1 : 0
  project = var.project_id
}

# One binding per consumer. count keys are static (booleans), so nothing here
# depends on an apply-time value for its for_each/count.
resource "google_kms_crypto_key_iam_member" "cloudsql" {
  count = var.grant_cloudsql ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.cloudsql[0].email}"
}

resource "google_kms_crypto_key_iam_member" "artifact_registry" {
  count = var.grant_artifact_registry ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.artifact_registry[0].email}"
}

resource "google_kms_crypto_key_iam_member" "storage" {
  count = var.grant_storage ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs[0].email_address}"
}
