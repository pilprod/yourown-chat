output "namespace_names" {
  description = "Names of the namespaces created by this module."
  value       = [for ns in kubernetes_namespace.this : ns.metadata[0].name]
}

output "secret_names" {
  description = "Map of logical key => created Secret name."
  value       = { for k, s in kubernetes_secret.this : k => s.metadata[0].name }
}
