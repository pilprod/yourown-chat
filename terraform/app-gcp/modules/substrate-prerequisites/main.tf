locals {
  substrate_namespace = "ate-system"
  repository_root     = abspath("${path.module}/../../../..")

  substrate_values_path       = "${local.repository_root}/helm/kagent/substrate.values.yaml"
  gateway_parameters_path     = "${local.repository_root}/helm/kagent/gateway/testbed-parameters.yaml"
  substrate_values            = try(file(local.substrate_values_path), "")
  gateway_parameters_source   = try(yamldecode(file(local.gateway_parameters_path)), {})
  gateway_parameters_sha256   = "2c00283a193c875397a94e018dbf799071b82293cd04f8c5d61e18d93349905f"
  expected_substrate_set_keys = toset(["image.registry", "image.digests.ateapi", "image.digests.atecontroller", "image.digests.atenet", "images.agentgateway"])
  substrate_image_values_valid = (
    toset(keys(var.substrate_helm_set_values)) == local.expected_substrate_set_keys &&
    can(regex("^[^@[:space:]]+(?:/[^@[:space:]]+)*$", try(var.substrate_helm_set_values["image.registry"], ""))) &&
    alltrue([
      for key in ["image.digests.ateapi", "image.digests.atecontroller", "image.digests.atenet"] :
      can(regex("^sha256:[0-9a-f]{64}$", try(var.substrate_helm_set_values[key], "")))
    ]) &&
    can(regex("^[^@[:space:]]+/[^@[:space:]]+@sha256:[0-9a-f]{64}$", try(var.substrate_helm_set_values["images.agentgateway"], "")))
  )
  substrate_image_values = {
    image = {
      registry = try(var.substrate_helm_set_values["image.registry"], "")
      digests = {
        ateapi        = try(var.substrate_helm_set_values["image.digests.ateapi"], "")
        atecontroller = try(var.substrate_helm_set_values["image.digests.atecontroller"], "")
        atenet        = try(var.substrate_helm_set_values["image.digests.atenet"], "")
      }
    }
    images = {
      agentgateway = try(var.substrate_helm_set_values["images.agentgateway"], "")
    }
  }

  # The tracked object carries the hardened proxy Pod contract. Terraform
  # replaces only the deployment-specific address name and adds ownership
  # labels; Cloud Deploy never owns or reapplies this shared resource.
  gateway_parameters_manifest = merge(local.gateway_parameters_source, {
    metadata = merge(try(local.gateway_parameters_source.metadata, {}), {
      namespace = local.substrate_namespace
      labels    = local.common_labels
    })
    spec = merge(try(local.gateway_parameters_source.spec, {}), {
      service = merge(try(local.gateway_parameters_source.spec.service, {}), {
        metadata = merge(try(local.gateway_parameters_source.spec.service.metadata, {}), {
          annotations = merge(try(local.gateway_parameters_source.spec.service.metadata.annotations, {}), {
            "networking.gke.io/load-balancer-ip-addresses" = var.agentgateway.public_ip_name
          })
        })
      })
    })
  })

  kagent_targets = merge([
    for control_key, control in var.kagent_control_planes : {
      for target_key, target in merge(
        {
          control = {
            namespace      = control.namespace
            migration_only = false
          }
        },
        {
          for agent_key, namespace in control.agent_namespaces : agent_key => {
            namespace      = namespace
            migration_only = false
          }
        },
        {
          for migration_key, namespace in control.migration_agent_namespaces : "migration-${migration_key}" => {
            namespace      = namespace
            migration_only = true
          }
        },
      ) :
      "${control_key}/${target_key}" => {
        namespace            = target.namespace
        controller_namespace = control.namespace
        release_name         = control.release_name
        migration_only       = target.migration_only
      }
    }
  ]...)

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
      namespace       = var.kagent_control_planes.prod.namespace
      kubernetes_name = "kagent-ate-client-tls"
      keys            = toset(["client-credential-bundle.pem", "server-ca.pem"])
    }
    kagent_dev_client_tls = {
      namespace       = var.kagent_control_planes.dev.namespace
      kubernetes_name = "kagent-dev-ate-client-tls"
      keys            = toset(["client-credential-bundle.pem", "server-ca.pem"])
    }
  }

  expected_derived_secret_contract = {
    actor_id_ca_certs = {
      source_secret_key = "actor_id_ca_pool"
      namespace         = local.substrate_namespace
      kubernetes_name   = "actor-id-ca-certs"
      keys              = toset(["ca.crt"])
    }
  }

  secret_contract_valid = (
    toset(keys(var.secret_contract)) == toset(keys(local.expected_secret_contract)) &&
    alltrue([
      for key, expected in local.expected_secret_contract :
      try(var.secret_contract[key].secret_manager_id != "", false) &&
      try(var.secret_contract[key].namespace == expected.namespace, false) &&
      try(var.secret_contract[key].kubernetes_name == expected.kubernetes_name, false) &&
      try(var.secret_contract[key].keys == expected.keys, false)
    ]) &&
    toset(keys(var.derived_secret_contract)) == toset(keys(local.expected_derived_secret_contract)) &&
    alltrue([
      for key, expected in local.expected_derived_secret_contract :
      try(var.derived_secret_contract[key].source_secret_key == expected.source_secret_key, false) &&
      try(var.derived_secret_contract[key].namespace == expected.namespace, false) &&
      try(var.derived_secret_contract[key].kubernetes_name == expected.kubernetes_name, false) &&
      try(var.derived_secret_contract[key].keys == expected.keys, false)
    ])
  )

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

  # These names deliberately never overlap objects rendered by either the
  # existing kagent or Substrate Helm releases. Bootstrap creates this
  # parallel permission set first; a later rbac.create=false Helm upgrade can
  # then prune only the old Helm-owned objects without interrupting either
  # service account.
  rbac_names = {
    kagent = {
      getter_role              = "kagent-control-plane-getter"
      getter_role_binding      = "kagent-control-plane-getter-binding"
      writer_role              = "kagent-control-plane-writer"
      writer_role_binding      = "kagent-control-plane-writer-binding"
      leader_role              = "kagent-control-plane-leader-election"
      leader_role_binding      = "kagent-control-plane-leader-election-binding"
      env_sources_role         = "kagent-substrate-env-source-reader"
      env_sources_role_binding = "kagent-substrate-env-source-reader-binding"
    }
    substrate = {
      api_role                = "substrate-api-server-reader"
      api_role_binding        = "substrate-api-server-reader-binding"
      controller_role         = "substrate-controller-actortemplate"
      controller_role_binding = "substrate-controller-actortemplate-binding"
    }
  }
}

import {
  for_each = var.adopt_existing && var.bootstrap_enabled ? toset([local.substrate_namespace]) : toset([])
  to       = kubernetes_namespace_v1.substrate[0]
  id       = each.value
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
      condition = (
        var.local_provider_only ||
        length(var.atenet_egress_destinations) > 0
      )
      error_message = "Substrate delivery remains closed until reviewed Actor/MCP CIDRs and ports are provided or local_provider_only explicitly disables Actor/MCP egress."
    }
  }
}

import {
  for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["${local.substrate_namespace}/substrate-crds"]) : toset([])
  to       = helm_release.substrate_crds[0]
  id       = each.value
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

# The application-specific agentgateway parameters are shared infrastructure,
# not a kagent promotion artifact. They must exist before the Substrate chart
# creates its Gateway with a parametersRef.
resource "kubernetes_manifest" "agentgateway_parameters" {
  count = var.release_enabled ? 1 : 0

  manifest = local.gateway_parameters_manifest

  field_manager {
    force_conflicts = true
    name            = "terraform-app-gcp"
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = filesha256(local.gateway_parameters_path) == local.gateway_parameters_sha256
      error_message = "The tracked AgentgatewayParameters manifest does not match its reviewed SHA-256."
    }

    precondition {
      condition = (
        try(local.gateway_parameters_source.apiVersion == "agentgateway.dev/v1alpha1", false) &&
        try(local.gateway_parameters_source.kind == "AgentgatewayParameters", false) &&
        try(local.gateway_parameters_source.metadata.name == "substrate-broker", false) &&
        var.agentgateway.public_ip_name != ""
      )
      error_message = "Substrate release requires the exact substrate-broker AgentgatewayParameters object and a dedicated GCP address resource name."
    }
  }

  depends_on = [
    helm_release.substrate_crds,
    kubernetes_role_binding_v1.agentgateway_deployer,
  ]
}

# Shared Substrate is installed once by app-gcp. Cloud Deploy promotes only
# kagent and never redeploys this release. The external-control-plane chart
# owns ate-api-server, ate-controller, atenet-egress, Gateway and TLSRoute.
import {
  for_each = var.adopt_existing && var.release_enabled ? toset(["${local.substrate_namespace}/substrate"]) : toset([])
  to       = helm_release.substrate_application[0]
  id       = each.value
}

resource "helm_release" "substrate_application" {
  count = var.release_enabled ? 1 : 0

  name             = "substrate"
  chart            = var.substrate_application_chart.ref
  version          = var.substrate_application_chart.version
  namespace        = kubernetes_namespace_v1.substrate[0].metadata[0].name
  create_namespace = false

  values = [
    local.substrate_values,
    yamlencode(local.substrate_image_values),
  ]

  atomic            = true
  cleanup_on_fail   = true
  dependency_update = false
  lint              = true
  max_history       = 5
  pass_credentials  = false
  replace           = false
  reset_values      = true
  reuse_values      = false
  skip_crds         = true
  timeout           = 900
  wait              = true
  wait_for_jobs     = true

  description = "Terraform-owned immutable Substrate external control plane"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = fileexists(local.substrate_values_path) && sha256(local.substrate_values) == var.substrate_values_sha256
      error_message = "The tracked Substrate application values file is missing or does not match the reviewed release checksum."
    }

    precondition {
      condition     = local.substrate_image_values_valid
      error_message = "The Substrate application must use only the exact immutable component image override keys."
    }
  }

  depends_on = [
    helm_release.substrate_crds,
    kubernetes_manifest.agentgateway_parameters,
    kubernetes_config_map_v1.authentication,
    kubernetes_cluster_role_binding_v1.substrate_api,
    kubernetes_cluster_role_binding_v1.substrate_controller,
    kubernetes_network_policy_v1.enrollment_admin_default_deny,
    kubernetes_network_policy_v1.substrate_api_external_egress,
    kubernetes_network_policy_v1.substrate_controller_api_egress,
    kubernetes_network_policy_v1.substrate_dns_egress,
  ]
}

# Read back every resource whose absence previously allowed release_ready to
# report a false positive on a fresh cluster. The data reads are deferred until
# the atomic Helm install has completed.
data "kubernetes_resource" "agentgateway_parameters" {
  count = var.release_enabled ? 1 : 0

  api_version = "agentgateway.dev/v1alpha1"
  kind        = "AgentgatewayParameters"
  metadata {
    name      = "substrate-broker"
    namespace = local.substrate_namespace
  }

  depends_on = [kubernetes_manifest.agentgateway_parameters]
}

data "kubernetes_resource" "substrate_api" {
  count = var.release_enabled ? 1 : 0

  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "ate-api-server"
    namespace = local.substrate_namespace
  }

  depends_on = [helm_release.substrate_application]
}

data "kubernetes_resource" "substrate_controller" {
  count = var.release_enabled ? 1 : 0

  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "ate-controller"
    namespace = local.substrate_namespace
  }

  depends_on = [helm_release.substrate_application]
}

data "kubernetes_resource" "external_provider_gateway" {
  count = var.release_enabled ? 1 : 0

  api_version = "gateway.networking.k8s.io/v1"
  kind        = "Gateway"
  metadata {
    name      = "external-provider-broker"
    namespace = local.substrate_namespace
  }

  depends_on = [helm_release.substrate_application]
}

data "kubernetes_resource" "external_provider_tls_route" {
  count = var.release_enabled ? 1 : 0

  api_version = "gateway.networking.k8s.io/v1"
  kind        = "TLSRoute"
  metadata {
    name      = "external-provider-broker"
    namespace = local.substrate_namespace
  }

  depends_on = [helm_release.substrate_application]
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

# The API resolves the in-cluster OIDC discovery/JWKS endpoints, while the
# controller and egress authorizer resolve the private ate-api Service. GKE
# Dataplane V2 may evaluate the translated DNS Pod destination rather than the
# Service IP, so admit both exact representations and both DNS transports.
resource "kubernetes_network_policy_v1" "substrate_dns_egress" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "substrate-control-plane-dns-egress"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_expressions {
        key      = "app"
        operator = "In"
        values   = ["ate-api-server", "ate-controller", "atenet-egress"]
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block { cidr = "${var.cluster_dns_ip}/32" }
      }
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        pod_selector {
          match_expressions {
            key      = "k8s-app"
            operator = "In"
            values   = ["kube-dns", "node-local-dns"]
          }
        }
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

# This policy is deliberately persistent and selects the fixed enrollment Pod
# identity before any one-shot issuer is created. The bootstrap script verifies
# this exact contract before adding its run-scoped allow policy, so an ambiguous
# client-side create can never leave a credential-bearing Pod unisolated.
resource "kubernetes_network_policy_v1" "enrollment_admin_default_deny" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "substrate-enrollment-admin-default-deny"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "substrate-enrollment-admin"
        "app.kubernetes.io/component" = "enrollment-admin"
        "app.kubernetes.io/part-of"   = "kagent-substrate-testbed"
      }
    }
    policy_types = ["Ingress", "Egress"]
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_network_policy_v1" "kagent_substrate_egress" {
  for_each = var.bootstrap_enabled ? var.kagent_control_planes : {}

  metadata {
    name      = "kagent-controller-substrate-egress"
    namespace = each.value.namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/instance"  = each.value.release_name
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

# Cloud Deploy verification runs in ate-system and checks each environment's
# controller health endpoint. Keep that bidirectional policy paired and scoped
# to the exact verifier and controller labels; neither side receives a generic
# namespace-wide allowance.
resource "kubernetes_network_policy_v1" "substrate_verifier_controller_egress" {
  for_each = var.bootstrap_enabled ? var.kagent_control_planes : {}

  metadata {
    name      = "kagent-${each.key}-verify-controller-egress"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = "verify"
        "app.kubernetes.io/part-of"   = "kagent-substrate-testbed"
      }
    }
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = each.value.namespace
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/name"      = "kagent"
            "app.kubernetes.io/instance"  = each.value.release_name
            "app.kubernetes.io/component" = "controller"
          }
        }
      }
      ports {
        port     = "8083"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_network_policy_v1" "kagent_controller_verifier_ingress" {
  for_each = var.bootstrap_enabled ? var.kagent_control_planes : {}

  metadata {
    name      = "substrate-verifier-controller-ingress"
    namespace = each.value.namespace
    labels    = local.common_labels
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name"      = "kagent"
        "app.kubernetes.io/instance"  = each.value.release_name
        "app.kubernetes.io/component" = "controller"
      }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = local.substrate_namespace
          }
        }
        pod_selector {
          match_labels = {
            "app.kubernetes.io/component" = "verify"
            "app.kubernetes.io/part-of"   = "kagent-substrate-testbed"
          }
        }
      }
      ports {
        port     = "8083"
        protocol = "TCP"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_network_policy_v1" "atenet_reviewed_egress" {
  for_each = var.bootstrap_enabled && !var.local_provider_only ? var.atenet_egress_destinations : {}

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

import {
  for_each = var.adopt_existing && var.bootstrap_enabled ? toset(["${local.substrate_namespace}/ate-api-authentication"]) : toset([])
  to       = kubernetes_config_map_v1.authentication[0]
  id       = each.value
}

resource "kubernetes_config_map_v1" "authentication" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "ate-api-authentication"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  data = { "authentication.yaml" = local.authentication }

  depends_on = [
    kubernetes_namespace_v1.substrate,
    kubernetes_service_account_v1.enrollment_admin,
  ]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = local.secret_contract_valid
      error_message = "Substrate/kagent require the exact nine source Secrets plus derived actor-id-ca-certs name, namespace, source and keys."
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

# Dev verification must run while this attestation is false. Production is
# independently fail-closed by a Cloud Deploy PREDEPLOY action that reads this
# single Terraform-managed record immediately before changing the prod release.
resource "kubernetes_config_map_v1" "production_promotion_gate" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kagent-production-promotion-gate"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  data = {
    "external_broker_smoke_ready" = tostring(var.external_broker_smoke_ready)
    "cloud_deploy_release"        = var.external_broker_smoke_release
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [kubernetes_namespace_v1.substrate]
}

resource "kubernetes_role_v1" "production_promotion_gate_reader" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kagent-production-promotion-gate-reader"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = [kubernetes_config_map_v1.production_promotion_gate[0].metadata[0].name]
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "production_promotion_gate_reader" {
  count = var.bootstrap_enabled ? 1 : 0

  metadata {
    name      = "kagent-production-promotion-gate-reader"
    namespace = local.substrate_namespace
    labels    = local.common_labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.production_promotion_gate_reader[0].metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = var.promotion_gate_reader_email
  }
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
# Terraform creates a parallel permission set under non-Helm names before the
# chart ownership handoff. The controller service account and permissions stay
# identical while the old Helm-owned RBAC is later pruned. The kagent.dev rules
# intentionally union live 0.9.12 agents APIs with the kap2 harness and template
# APIs until the migration-only prod namespace has been drained.
resource "kubernetes_role_v1" "kagent_getter" {
  for_each = var.bootstrap_enabled ? local.kagent_targets : {}
  metadata {
    name      = local.rbac_names.kagent.getter_role
    namespace = each.value.namespace
    labels    = local.common_labels
  }

  rule {
    api_groups = ["kagent.dev"]
    resources  = ["agents", "harnesses", "agenttemplates", "sandboxagents", "agentharnesses", "modelconfigs", "modelproviderconfigs", "toolservers", "memories", "remotemcpservers", "mcpservers"]
    verbs      = ["get", "list", "watch"]
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["agents/finalizers", "harnesses/finalizers", "agenttemplates/finalizers", "sandboxagents/finalizers", "agentharnesses/finalizers", "modelconfigs/finalizers", "modelproviderconfigs/finalizers", "toolservers/finalizers", "memories/finalizers", "remotemcpservers/finalizers", "mcpservers/finalizers"]
    verbs      = ["update"]
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["agents/status", "harnesses/status", "agenttemplates/status", "sandboxagents/status", "agentharnesses/status", "modelconfigs/status", "modelproviderconfigs/status", "toolservers/status", "memories/status", "remotemcpservers/status", "mcpservers/status"]
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
  for_each = var.bootstrap_enabled ? local.kagent_targets : {}
  metadata {
    name      = local.rbac_names.kagent.writer_role
    namespace = each.value.namespace
    labels    = local.common_labels
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["agents", "harnesses", "agenttemplates", "sandboxagents", "agentharnesses", "modelconfigs", "modelproviderconfigs", "toolservers", "memories", "remotemcpservers", "mcpservers"]
    verbs      = ["create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["kagent.dev"]
    resources  = ["agents/finalizers", "harnesses/finalizers", "agenttemplates/finalizers", "sandboxagents/finalizers", "agentharnesses/finalizers", "modelconfigs/finalizers", "modelproviderconfigs/finalizers", "toolservers/finalizers", "memories/finalizers", "remotemcpservers/finalizers", "mcpservers/finalizers"]
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
    name      = local.rbac_names.kagent.getter_role_binding
    namespace = each.value.metadata[0].namespace
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
    namespace = local.kagent_targets[each.key].controller_namespace
  }
}

resource "kubernetes_role_binding_v1" "kagent_writer" {
  for_each = kubernetes_role_v1.kagent_writer
  metadata {
    name      = local.rbac_names.kagent.writer_role_binding
    namespace = each.value.metadata[0].namespace
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
    namespace = local.kagent_targets[each.key].controller_namespace
  }
}

resource "kubernetes_role_v1" "kagent_leader_election" {
  for_each = var.bootstrap_enabled ? var.kagent_control_planes : {}
  metadata {
    name      = local.rbac_names.kagent.leader_role
    namespace = each.value.namespace
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
  for_each = kubernetes_role_v1.kagent_leader_election
  metadata {
    name      = local.rbac_names.kagent.leader_role_binding
    namespace = each.value.metadata[0].namespace
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
    namespace = var.kagent_control_planes[each.key].namespace
  }
}

# ate-api-server needs env-source reads only for the target control and
# declarative agent namespaces. Neither live 0.9.12 nor kap2 grants this access
# in the legacy migration namespace, so fail closed by filtering it out.
resource "kubernetes_role_v1" "kagent_env_sources" {
  for_each = var.bootstrap_enabled ? {
    for target_key, target in local.kagent_targets : target_key => target
    if !target.migration_only
  } : {}
  metadata {
    name      = local.rbac_names.kagent.env_sources_role
    namespace = each.value.namespace
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
    name      = local.rbac_names.kagent.env_sources_role_binding
    namespace = each.value.metadata[0].namespace
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

# This parallel permission set deliberately does not import the existing
# Helm-owned ClusterRoles or ClusterRoleBindings. It is created before the
# application release is adopted, so the subsequent rbac.create=false upgrade
# can remove Helm's old names without creating a permission gap.
resource "kubernetes_cluster_role_v1" "substrate_api" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = local.rbac_names.substrate.api_role
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

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_cluster_role_binding_v1" "substrate_api" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = local.rbac_names.substrate.api_role_binding
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

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_cluster_role_v1" "substrate_controller" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = local.rbac_names.substrate.controller_role
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

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_cluster_role_binding_v1" "substrate_controller" {
  count = var.bootstrap_enabled ? 1 : 0
  metadata {
    name   = local.rbac_names.substrate.controller_role_binding
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

  lifecycle {
    prevent_destroy = true
  }
}
