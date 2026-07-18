# Tenant namespaces + credential Secrets, created straight in the cluster by
# Terraform. The secret VALUES arrive as Terraform inputs (a generated password,
# or values read back from Secret Manager) and land only in Terraform state
# (HCP, encrypted) and etcd -- they never pass through a Cloud Deploy deploy
# parameter or a rendered manifest.
#
# Terraform owns the namespaces so this stack can create the Secrets before
# Cloud Deploy runs (Cloud Deploy only deploys workloads INTO these namespaces).
resource "kubernetes_namespace" "this" {
  for_each = var.namespaces

  metadata {
    name   = each.key
    labels = each.value.labels
  }
}

locals {
  # var.secrets is sensitive (its `data` values are), and for_each cannot take a
  # sensitive collection. The KEYS (logical secret names) are NOT secret, so
  # unwrap just the key set for for_each and read each secret's fields back by
  # key. try() falls back when nothing is sensitive (e.g. an empty map).
  secret_keys = try(nonsensitive(toset(keys(var.secrets))), toset(keys(var.secrets)))
}

resource "kubernetes_secret" "this" {
  for_each = local.secret_keys

  metadata {
    name      = var.secrets[each.value].name
    namespace = var.secrets[each.value].namespace
    labels    = var.secrets[each.value].labels
  }

  # Plaintext in; the provider stores it base64-encoded. Marked sensitive.
  data = var.secrets[each.value].data
  type = var.secrets[each.value].type

  # The namespace must exist first (secret.namespace is a plain string, so add
  # the dependency explicitly).
  depends_on = [kubernetes_namespace.this]
}
