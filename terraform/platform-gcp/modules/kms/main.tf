# ---------------------------------------------------------------------------
# One shared CMEK key for the platform. A single symmetric key wraps the
# data-encryption keys (DEKs) of every at-rest store that supports CMEK:
#   - Cloud SQL (Postgres)     -- database component
#   - Cloud Storage (filestore)-- storage component
#   - Secret Manager (secrets) -- secrets component
#   - GKE etcd (K8s Secrets)   -- gke component (application-layer encryption)
# The container registry is PUBLIC and is NOT CMEK-encrypted, so this key has no
# image-CI consumer (grant_artifact_registry defaults on but is disabled by the
# kms component). The key is regional (must match every consumer's region).
#
# Cost: a KMS key ring is free; you pay per active key version (~$1.00/mo for an
# HSM version, ~$0.06 for SOFTWARE) plus negligible wrap/unwrap operations. One
# shared key = one active version, so the whole platform's CMEK is ~$1/mo.
#
# Teardown note: Cloud KMS key rings and keys CANNOT be deleted from GCP -- only
# key VERSIONS can be scheduled for destruction. On `terraform destroy` the
# provider drops them from state (they persist in the project), so a later
# re-apply with the SAME names is a no-op import-or-conflict rather than a fresh
# create. Names are deliberately stable (no random suffix) because the
# artifact_registry component references the key by its deterministic path.
# ---------------------------------------------------------------------------

locals {
  # Regional names, project prefix dropped (the project is already yourown-chat).
  # No "-keyring" type suffix: it is THE keyring, named after its location alone
  # (mirroring the GKE cluster / Cloud SQL instance). The location scope keeps it
  # collision-free for a second-region deployment; consumers reference the key by
  # this deterministic path.
  key_ring_name   = var.location
  crypto_key_name = "cmek"
}

resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = local.key_ring_name
  location = var.location
}

# Adopt the pre-existing key ring + key instead of re-creating them. Cloud KMS
# objects can NEVER be deleted from GCP (only key versions can), so after any
# teardown the same-named ring/key still exist and a fresh create 409s. Gated
# by a flag (default off) so a genuinely new project still creates normally;
# when on, Terraform imports both into state on the next apply (a no-op once
# they are already in state). Config-driven import is accepted by Stacks.
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
# GA data source; Cloud SQL, Artifact Registry and Secret Manager need the beta
# identity resource.
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

resource "google_kms_crypto_key_iam_member" "secretmanager" {
  count = var.grant_secretmanager ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.secretmanager[0].email}"
}

# The GKE service agent (service-<num>@container-engine-robot) is auto-created
# when the container API is enabled (project_services, upstream of this
# component), so the grant below never races a missing principal. Its email is
# built from the project number (threaded in, not a data source, to avoid a
# resourcemanager.projects.get dependency on the apply SA).
resource "google_kms_crypto_key_iam_member" "gke" {
  count = var.grant_gke ? 1 : 0

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${var.project_number}@container-engine-robot.iam.gserviceaccount.com"
}
