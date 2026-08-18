output "issuer" {
  value = "${var.public_url}/realms/yourown-chat"
}

output "internal_url" {
  value = var.enabled ? "http://keycloak.${var.namespace}.svc.cluster.local:8080" : null
}

output "namespace" {
  value = var.enabled ? var.namespace : null
}
