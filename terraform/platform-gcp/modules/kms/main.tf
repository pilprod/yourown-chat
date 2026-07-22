# One shared regional CMEK key wrapping the DEKs of Cloud SQL, GCS, Secret
# Manager and GKE etcd (the public registry is not CMEK). ~$1/mo (one HSM
# version). Names are stable/deterministic because consumers reference the key
# by path, and KMS rings/keys can never be deleted from GCP (only versions).

locals {
  key_ring_name   = var.location
  crypto_key_name = "cmek"
}

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = local.key_ring_name
  location = var.location
}

# Adopt the pre-existing ring/key (a fresh create 409s -- KMS objects survive
# teardown). Gated by a flag so a genuinely new project still creates normally.
import {
  for_each = var.adopt_existing ? toset([local.key_ring_name]) : toset([])
  to       = google_kms_key_ring.this
  id       = "projects/${var.project_id}/locations/${var.location}/keyRings/${each.value}"
}

import {
  for_each = var.adopt_existing ? toset([local.crypto_key_name]) : toset([])
  to       = google_kms_crypto_key.this
  id       = "projects/${var.project_id}/locations/${var.location}/keyRings/${local.key_ring_name}/cryptoKeys/${each.value}"
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

# Force-create each consuming service's per-project agent so the IAM grants
# below never race a not-yet-existent principal.
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

resource "google_project_service_identity" "secretmanager" {
  count    = var.grant_secretmanager ? 1 : 0
  provider = google-beta

  project = var.project_id
  service = "secretmanager.googleapis.com"
}

data "google_storage_project_service_account" "gcs" {
  count   = var.grant_storage ? 1 : 0
  project = var.project_id
}

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

resource "google_kms_crypto_key_iam_member" "secretmanager" {
  count = var.grant_secretmanager ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secretmanager[0].email}"
}

# GKE service agent email built from the project number (not a data source, to
# avoid a resourcemanager.projects.get dependency on the apply SA).
resource "google_kms_crypto_key_iam_member" "gke" {
  count = var.grant_gke ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com"
}
