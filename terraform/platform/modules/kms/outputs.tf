output "crypto_key_id" {
  type        = string
  description = "Full resource ID of the shared CMEK key (projects/<p>/locations/<loc>/keyRings/<ring>/cryptoKeys/<key>). Wire this into every platform CMEK consumer (Cloud SQL, GCS, Secret Manager)."
  value       = google_kms_crypto_key.this.id
}

output "key_ring_id" {
  type        = string
  description = "Full resource ID of the key ring."
  value       = google_kms_key_ring.this.id
}

output "crypto_key_name" {
  type        = string
  description = "Short name of the crypto key."
  value       = google_kms_crypto_key.this.name
}
