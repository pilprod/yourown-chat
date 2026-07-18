output "namespace_names" {
  description = "Names of the namespaces created by this module."
  value       = [for ns in kubernetes_namespace.this : ns.metadata[0].name]
}

output "secret_names" {
  description = "Map of logical key => created Secret name. Secret names are not secret; unwrap the sensitivity inherited from the (sensitive) secrets input."
  value = try(
    nonsensitive({ for k, s in kubernetes_secret.this : k => s.metadata[0].name }),
    { for k, s in kubernetes_secret.this : k => s.metadata[0].name },
  )
}
