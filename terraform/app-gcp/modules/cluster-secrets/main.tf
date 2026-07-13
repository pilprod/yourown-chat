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

resource "kubernetes_secret" "this" {
  for_each = var.secrets

  metadata {
    name      = each.value.name
    namespace = each.value.namespace
    labels    = each.value.labels
  }

  # Plaintext in; the provider stores it base64-encoded. Marked sensitive.
  data = each.value.data
  type = each.value.type

  # The namespace must exist first (secret.namespace is a plain string, so add
  # the dependency explicitly).
  depends_on = [kubernetes_namespace.this]
}
