# Namespace-scoped RBAC for the dev tenant, created by Terraform (via the apply
# SA, which holds roles/container.admin -> can manage Kubernetes RBAC). Cloud
# Deploy's execution SA is deliberately roles/container.developer, which GKE
# forbids from creating Roles/RoleBindings (privilege-escalation prevention),
# so this must NOT be applied by Cloud Deploy.
#
# Gated on var.subjects: with no subjects (the default) nothing is created --
# there is no point binding the dev team's edit rights to a placeholder. Provide
# the real dev-team Group (needs "Google Groups for GKE RBAC") or kind: User
# subjects to enable it. There is deliberately NO ClusterRole/ClusterRoleBinding:
# the dev team is confined to the `dev` namespace (the RBAC half of dev/prod
# isolation; NetworkPolicies are the network half).
locals {
  enabled = length(var.subjects) > 0
}

resource "kubernetes_role" "dev_tenant" {
  count = local.enabled ? 1 : 0

  metadata {
    name      = "dev-tenant"
    namespace = var.namespace
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec", "pods/portforward", "services", "endpoints", "configmaps", "secrets", "persistentvolumeclaims", "events"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "replicasets", "daemonsets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_role_binding" "dev_tenant" {
  count = local.enabled ? 1 : 0

  metadata {
    name      = "dev-tenant"
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.dev_tenant[0].metadata[0].name
  }

  dynamic "subject" {
    for_each = var.subjects
    content {
      api_group = "rbac.authorization.k8s.io"
      kind      = subject.value.kind
      name      = subject.value.name
    }
  }
}
