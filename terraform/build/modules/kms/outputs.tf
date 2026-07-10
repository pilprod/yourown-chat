output "crypto_key_id" {
  type        = string
  description = "Full resource ID of the build-owned CMEK key (projects/<p>/locations/<loc>/keyRings/<ring>/cryptoKeys/<key>). Wired into the github-pat secret's user-managed replica as its CMEK."
  value       = google_kms_crypto_key.this.id
}

output "key_ring_id" {
  type        = string
  description = "Full resource ID of the key ring."
  value       = google_kms_key_ring.this.id
}
