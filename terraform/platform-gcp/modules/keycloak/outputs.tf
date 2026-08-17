output "issuer" {
  value = "${var.public_url}/realms/yourown-chat"
}

output "internal_url" {
  value = var.enabled ? "http://keycloak.${var.namespace}.svc.cluster.local:8080" : null
}

output "namespace" {
  value = var.enabled ? var.namespace : null
}

output "bootstrap_admin_secret_id" {
  value = one(google_secret_manager_secret.bootstrap_admin[*].secret_id)
}
