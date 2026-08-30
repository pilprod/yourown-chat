locals {
  substrate_namespace = "ate-system"
  kagent_namespace    = "kagent-system"
  workload_namespace  = "kagent-testbed"

  expected_secret_contract = {
    postgres = {
      namespace       = local.substrate_namespace
      kubernetes_name = "substrate-cloud-sql"
      keys            = toset(["connection-string"])
    }
    api_tls = {
      namespace       = local.substrate_namespace
      kubernetes_name = "substrate-ate-api-tls"
      keys            = toset(["server-credential-bundle.pem", "client-ca.pem"])
    }
    controller_tls = {
      namespace       = local.substrate_namespace
      kubernetes_name = "substrate-ate-controller-tls"
      keys            = toset(["client-credential-bundle.pem", "server-ca.pem"])
    }
    egress_gateway_tls = {
      namespace       = local.substrate_namespace
      kubernetes_name = "substrate-atenet-egress-server-tls"
      keys            = toset(["server-credential-bundle.pem", "server-ca.pem"])
    }
    egress_authorizer_tls = {
      namespace       = local.substrate_namespace
      kubernetes_name = "substrate-atenet-egress-client-tls"
      keys            = toset(["client-credential-bundle.pem", "server-ca.pem"])
    }
    actor_id_jwt_pool = {
      namespace       = local.substrate_namespace
      kubernetes_name = "actor-id-jwt-pool"
      keys            = toset(["pool"])
    }
    actor_id_ca_pool = {
      namespace       = local.substrate_namespace
      kubernetes_name = "actor-id-ca-pool"
      keys            = toset(["pool"])
    }
    kagent_client_tls = {
      namespace       = local.kagent_namespace
      kubernetes_name = "kagent-ate-client-tls"
      keys            = toset(["client-credential-bundle.pem", "server-ca.pem"])
    }
  }

  secret_contract_valid = toset(keys(var.secret_contract)) == toset(keys(local.expected_secret_contract)) && alltrue([
    for key, expected in local.expected_secret_contract :
    try(var.secret_contract[key].secret_manager_id != "", false) &&
    try(var.secret_contract[key].namespace == expected.namespace, false) &&
    try(var.secret_contract[key].kubernetes_name == expected.kubernetes_name, false) &&
    try(var.secret_contract[key].keys == expected.keys, false)
  ])

  authentication = yamlencode({
    actorIdentityJWTProvider = "kubernetes"
    externalProviderEnrollmentAdmins = [{
      provider = "kubernetes"
      subjects = ["system:serviceaccount:${local.substrate_namespace}:ate-enrollment-admin"]
    }]
    jwtProviders = [{
      name                     = "kubernetes"
      issuer                   = "https://container.googleapis.com/v1/${var.gke_cluster_id}"
      audiences                = ["api.${local.substrate_namespace}.svc"]
      discoveryURL             = "https://kubernetes.default.svc/.well-known/openid-configuration"
      jwksURL                  = "https://kubernetes.default.svc/openid/v1/jwks"
      certificateAuthorityFile = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
      discoveryTokenFile       = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    }]
  })

  common_labels = merge(var.labels, {
    "app.kubernetes.io/part-of"    = "kagent-substrate-testbed"
    "app.kubernetes.io/managed-by" = "terraform"
  })
}

resource "kubernetes_namespace_v1" "substrate" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name = local.substrate_namespace
    labels = merge(local.common_labels, {
      "gateway-controller"                         = "agentgateway"
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    })
  }

  lifecycle {
    precondition {
      condition     = length(var.atenet_egress_destinations) > 0
      error_message = "Substrate delivery remains closed until reviewed Actor/MCP CIDRs and ports are provided for atenet-egress."
    }
  }
}

resource "helm_release" "substrate_crds" {
  count = var.bootstrap_enabled ? 1 : 0

  name             = "substrate-crds"
  chart            = var.substrate_crd_chart.ref
  version          = var.substrate_crd_chart.version
  namespace        = kubernetes_namespace_v1.substrate[0].metadata[0].name
  create_namespace = false

  atomic            = false
  cleanup_on_fail   = false
  dependency_update = false
  lint              = true
  max_history       = 5
  pass_credentials  = false
  replace           = false
  reset_values      = true
  reuse_values      = false
  timeout           = 900
  wait              = true
  wait_for_jobs     = true

  description = "Terraform-owned immutable Substrate CRDs for the external-control-plane testbed"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

data "kubernetes_service_v1" "api" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

data "kubernetes_endpoints_v1" "api" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kubernetes"
    namespace = "default"
  }
}

locals {
  kubernetes_api_service_ip = try(data.kubernetes_service_v1.api[0].spec[0].cluster_ip, null)
  kubernetes_api_https_subsets = [
    for subset in try(data.kubernetes_endpoints_v1.api[0].subset, []) : subset
    if anytrue([
      for port in subset.port : port.port == 443 && port.protocol == "TCP"
    ])
  ]
  kubernetes_api_endpoint_ips = toset(flatten([
    for subset in local.kubernetes_api_https_subsets : [
      for address in subset.address : address.ip
    ]
  ]))
  kubernetes_api_destination_ips = setunion(
    local.kubernetes_api_service_ip == null ? toset([]) : toset([local.kubernetes_api_service_ip]),
    local.kubernetes_api_endpoint_ips,
  )
}

resource "kubernetes_network_policy_v1" "substrate_api_external_egress" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "substrate-api-exact-external-egress"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = { app = "ate-api-server" }
    }
    policy_types = ["Egress"]

    egress {
      dynamic "to" {
        for_each = local.kubernetes_api_destination_ips
        iterator = destination
        content {
          ip_block { cidr = "${destination.value}/32" }
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    egress {
      to {
        ip_block { cidr = "${var.cloudsql_private_ip}/32" }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.kubernetes_api_endpoint_ips) > 0
      error_message = "The Kubernetes Service must publish at least one ready TCP/443 endpoint before ate-api egress can open."
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_network_policy_v1" "substrate_controller_api_egress" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "substrate-controller-exact-api-egress"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = { app = "ate-controller" }
    }
    policy_types = ["Egress"]
    egress {
      dynamic "to" {
        for_each = local.kubernetes_api_destination_ips
        iterator = destination
        content {
          ip_block { cidr = "${destination.value}/32" }
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.kubernetes_api_endpoint_ips) > 0
      error_message = "The Kubernetes Service must publish at least one ready TCP/443 endpoint before ate-controller egress can open."
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_network_policy_v1" "kagent_substrate_egress" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kagent-controller-substrate-egress"
    namespace = local.kagent_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/instance"  = "kagent"
        "app.kubernetes.io/component" = "controller"
      }
    }
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.substrate_namespace
          }
        }
        pod_selector {
          match_labels = { app = "ate-api-server" }
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_network_policy_v1" "atenet_reviewed_egress" {
  for_each = var.bootstrap_enabled ? var.atenet_egress_destinations : {}

  metadata {
    name      = "atenet-egress-${each.key}"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = { app = "atenet-egress" }
    }
    policy_types = ["Egress"]
    egress {
      to {
        ip_block { cidr = each.value.cidr }
      }
      ports {
        port     = tostring(each.value.port)
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_config_map_v1" "authentication" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "ate-api-authentication"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  data = { "authentication.yaml" = local.authentication }

  depends_on = [kubernetes_namespace_v1.substrate]

  lifecycle {
    precondition {
      condition     = local.secret_contract_valid
      error_message = "Substrate/kagent require the exact DB, API/controller/egress TLS, identity-pool and kagent client TLS Secret names, namespaces and keys."
    }
  }
}

resource "kubernetes_service_account_v1" "enrollment_admin" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name      = "ate-enrollment-admin"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }
  automount_service_account_token = false

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_role_v1" "testbed_verifier" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kagent-substrate-testbed-verifier"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  rule {
    api_groups = ["gateway.networking.k8s.io"]
    resources  = ["gateways", "gateways/status", "tlsroutes", "tlsroutes/status"]
    verbs      = ["get"]
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_role_binding_v1" "testbed_verifier" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kagent-substrate-testbed-verifier"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.testbed_verifier[0].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.enrollment_admin[0].metadata[0].name
    namespace = local.substrate_namespace
  }
}

resource "kubernetes_role_binding_v1" "agentgateway_deployer" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name      = "agentgateway-write-role-${var.agentgateway.namespace}"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = var.agentgateway.deployer_cluster_role_name
  }
  subject {
    kind      = "ServiceAccount"
    name      = var.agentgateway.service_account_name
    namespace = var.agentgateway.namespace
  }
  depends_on = [kubernetes_namespace_v1.substrate]
}

# kagent fork artifacts admitted to this rail must support rbac.create=false.
# Terraform owns the controller's two namespace-scoped roles and bindings.
resource "kubernetes_role_v1" "kagent_getter" {
  for_each = var.bootstrap_enabled ? toset([local.kagent_namespace, local.workload_namespace]) : toset([])
  metadata {
    name      = "kagent-getter-role"
    namespace = each.value
    labels    = local.common_labels
  }

  rule {
    api_groups = ["kagent.dev"]
    resources  = ["harnesses", "agenttemplates", "sandboxagents", "agentharnesses", "modelconfigs", "modelproviderconfigs", "toolservers", "memories", "remotemcpservers", "mcpservers"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["harnesses/finalizers", "agenttemplates/finalizers", "sandboxagents/finalizers", "agentharnesses/finalizers", "modelconfigs/finalizers", "modelproviderconfigs/finalizers", "toolservers/finalizers", "memories/finalizers", "remotemcpservers/finalizers", "mcpservers/finalizers"]
    verbs      = ["update"]
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["harnesses/status", "agenttemplates/status", "sandboxagents/status", "agentharnesses/status", "modelconfigs/status", "modelproviderconfigs/status", "toolservers/status", "memories/status", "remotemcpservers/status", "mcpservers/status"]
    verbs      = ["get", "patch", "update"]
  }
  dynamic "rule" {
    for_each = {
      core      = { groups = [""], resources = ["*"] }
      apps      = { groups = ["apps"], resources = ["*"] }
      batch     = { groups = ["batch"], resources = ["*"] }
      rbac      = { groups = ["rbac.authorization.k8s.io"], resources = ["*"] }
      gateway   = { groups = ["gateway.networking.k8s.io"], resources = ["*"] }
      substrate = { groups = ["ate.dev"], resources = ["workerpools", "actortemplates"] }
      sandbox   = { groups = ["agents.x-k8s.io"], resources = ["sandboxes"] }
    }
    content {
      api_groups = rule.value.groups
      resources  = rule.value.resources
      verbs      = ["get", "list", "watch"]
    }
  }
  rule {
    api_groups = ["ate.dev"]
    resources  = ["actortemplates/status"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_v1" "kagent_writer" {
  for_each = var.bootstrap_enabled ? toset([local.kagent_namespace, local.workload_namespace]) : toset([])
  metadata {
    name      = "kagent-writer-role"
    namespace = each.value
    labels    = local.common_labels
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["harnesses", "agenttemplates", "sandboxagents", "agentharnesses", "modelconfigs", "modelproviderconfigs", "toolservers", "memories", "remotemcpservers", "mcpservers"]
    verbs      = ["create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["harnesses/finalizers", "agenttemplates/finalizers", "sandboxagents/finalizers", "agentharnesses/finalizers", "modelconfigs/finalizers", "modelproviderconfigs/finalizers", "toolservers/finalizers", "memories/finalizers", "remotemcpservers/finalizers", "mcpservers/finalizers"]
    verbs      = ["update"]
  }
  dynamic "rule" {
    for_each = {
      core      = { groups = [""], resources = ["*"] }
      apps      = { groups = ["apps"], resources = ["*"] }
      batch     = { groups = ["batch"], resources = ["*"] }
      gateway   = { groups = ["gateway.networking.k8s.io"], resources = ["*"] }
      substrate = { groups = ["ate.dev"], resources = ["actortemplates"] }
      sandbox   = { groups = ["agents.x-k8s.io"], resources = ["sandboxes"] }
    }
    content {
      api_groups = rule.value.groups
      resources  = rule.value.resources
      verbs      = ["create", "update", "patch", "delete"]
    }
  }
}

resource "kubernetes_role_binding_v1" "kagent_getter" {
  for_each = kubernetes_role_v1.kagent_getter
  metadata {
    name      = "kagent-getter-rolebinding"
    namespace = each.key
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kagent-controller"
    namespace = local.kagent_namespace
  }
}

resource "kubernetes_role_binding_v1" "kagent_writer" {
  for_each = kubernetes_role_v1.kagent_writer
  metadata {
    name      = "kagent-writer-rolebinding"
    namespace = each.key
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kagent-controller"
    namespace = local.kagent_namespace
  }
}

resource "kubernetes_role_v1" "kagent_leader_election" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name      = "kagent-leader-election-role"
    namespace = local.kagent_namespace
    labels    = local.common_labels
  }
  rule {
    api_groups = ["coordination.k8s.io"]
    resources  = ["leases"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["create", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "kagent_leader_election" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name      = "kagent-leader-election-rolebinding"
    namespace = local.kagent_namespace
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.kagent_leader_election[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kagent-controller"
    namespace = local.kagent_namespace
  }
}

resource "kubernetes_role_v1" "kagent_env_sources" {
  for_each = var.bootstrap_enabled ? toset([local.kagent_namespace, local.workload_namespace]) : toset([])
  metadata {
    name      = "kagent-ate-api-env-sources"
    namespace = each.value
    labels    = local.common_labels
  }
  rule {
    api_groups = [""]
    resources  = ["secrets", "configmaps"]
    verbs      = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "kagent_env_sources" {
  for_each = kubernetes_role_v1.kagent_env_sources
  metadata {
    name      = "kagent-ate-api-env-sources"
    namespace = each.key
    labels    = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = each.value.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ate-api-server"
    namespace = local.substrate_namespace
  }
}

# The Substrate external profile needs only these two cluster read/status roles.
resource "kubernetes_cluster_role_v1" "substrate_api" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = "ate-api-server-role"
    labels = local.common_labels
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = ["ate.dev"]
    resources  = ["actortemplates", "workerpools", "sandboxconfigs", "csidriverconfigs"]
    verbs      = ["get", "watch", "list"]
  }
  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "watch", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "substrate_api" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = "ate-api-server-binding"
    labels = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.substrate_api[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ate-api-server"
    namespace = local.substrate_namespace
  }
}

resource "kubernetes_cluster_role_v1" "substrate_controller" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = "ate-controller"
    labels = local.common_labels
  }
  rule {
    api_groups = ["ate.dev"]
    resources  = ["actortemplates"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["ate.dev"]
    resources  = ["actortemplates/status"]
    verbs      = ["get", "patch", "update"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "substrate_controller" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = "ate-controller"
    labels = local.common_labels
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.substrate_controller[0].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = "ate-controller"
    namespace = local.substrate_namespace
  }
}
