mock_provider "helm" {
  mock_resource "helm_release" {
    defaults = {
      status = "deployed"
    }
  }
}

mock_provider "kubernetes" {
  mock_data "kubernetes_service_v1" {
    defaults = {
      spec = [{
        cluster_ip = "10.96.0.1"
      }]
    }
  }

  mock_data "kubernetes_endpoints_v1" {
    defaults = {
      subset = [{
        address = [{ ip = "10.0.0.2" }]
        port    = [{ port = 443, protocol = "TCP" }]
      }]
    }
  }
}

variables {
  bootstrap_enabled = true
  release_enabled   = false
  gke_cluster_id    = "projects/test-project/locations/europe-west3-b/clusters/test-cluster"

  native_secret_sync_ready    = false
  promotion_gate_reader_email = "deploy-gate@test-project.iam.gserviceaccount.com"
  local_provider_only         = true
  cloudsql_private_ip         = "10.20.0.3"
  cluster_dns_ip              = "10.96.0.10"
  atenet_egress_destinations  = {}
  substrate_helm_set_values   = {}
  substrate_values_sha256     = ""

  substrate_crd_chart = {
    ref     = "oci://example.invalid/substrate-crds@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    version = "0.0.22"
  }

  kagent_control_planes = {
    prod = {
      namespace    = "kagent-system"
      release_name = "kagent"
      agent_namespaces = {
        codex = "agent-codex"
      }
      migration_agent_namespaces = {
        legacy = "kagent-testbed"
      }
    }
    dev = {
      namespace    = "kagent-dev"
      release_name = "kagent-dev"
      agent_namespaces = {
        codex = "agent-codex-dev"
      }
      migration_agent_namespaces = {}
    }
  }

  secret_contract = {
    postgres = {
      secret_manager_id = "substrate-database-url"
      namespace         = "ate-system"
      kubernetes_name   = "substrate-cloud-sql"
      keys              = ["connection-string"]
    }
    api_tls = {
      secret_manager_id = "substrate-ate-api-tls"
      namespace         = "ate-system"
      kubernetes_name   = "substrate-ate-api-tls"
      keys              = ["server-credential-bundle.pem", "client-ca.pem"]
    }
    controller_tls = {
      secret_manager_id = "substrate-ate-controller-tls"
      namespace         = "ate-system"
      kubernetes_name   = "substrate-ate-controller-tls"
      keys              = ["client-credential-bundle.pem", "server-ca.pem"]
    }
    egress_gateway_tls = {
      secret_manager_id = "substrate-atenet-egress-server-tls"
      namespace         = "ate-system"
      kubernetes_name   = "substrate-atenet-egress-server-tls"
      keys              = ["server-credential-bundle.pem", "server-ca.pem"]
    }
    egress_authorizer_tls = {
      secret_manager_id = "substrate-atenet-egress-client-tls"
      namespace         = "ate-system"
      kubernetes_name   = "substrate-atenet-egress-client-tls"
      keys              = ["client-credential-bundle.pem", "server-ca.pem"]
    }
    actor_id_jwt_pool = {
      secret_manager_id = "substrate-actor-id-jwt-pool"
      namespace         = "ate-system"
      kubernetes_name   = "actor-id-jwt-pool"
      keys              = ["pool"]
    }
    actor_id_ca_pool = {
      secret_manager_id = "substrate-actor-id-ca-pool"
      namespace         = "ate-system"
      kubernetes_name   = "actor-id-ca-pool"
      keys              = ["pool"]
    }
    kagent_client_tls = {
      secret_manager_id = "kagent-ate-client-tls"
      namespace         = "kagent-system"
      kubernetes_name   = "kagent-ate-client-tls"
      keys              = ["client-credential-bundle.pem", "server-ca.pem"]
    }
    kagent_dev_client_tls = {
      secret_manager_id = "kagent-dev-ate-client-tls"
      namespace         = "kagent-dev"
      kubernetes_name   = "kagent-dev-ate-client-tls"
      keys              = ["client-credential-bundle.pem", "server-ca.pem"]
    }
  }

  derived_secret_contract = {
    actor_id_ca_certs = {
      source_secret_key = "actor_id_ca_pool"
      namespace         = "ate-system"
      kubernetes_name   = "actor-id-ca-certs"
      keys              = ["ca.crt"]
    }
  }

  agentgateway = {
    namespace                  = "agentgateway-system"
    service_account_name       = "agentgateway"
    deployer_cluster_role_name = "agentgateway-deployer"
    public_ip_name             = "agentgateway-public"
  }
}

run "bootstrap_creates_parallel_rbac_names" {
  command = plan

  # The Kubernetes provider mock cannot synthesize nested Endpoint blocks for
  # these unrelated live-cluster preconditions. The assertions in this run
  # target only the bootstrap RBAC graph.
  expect_failures = [
    kubernetes_network_policy_v1.substrate_api_external_egress,
    kubernetes_network_policy_v1.substrate_controller_api_egress,
  ]

  override_data {
    target = data.kubernetes_service_v1.api[0]
    values = {
      spec = [{
        cluster_ip = "10.96.0.1"
      }]
    }
  }

  override_data {
    target = data.kubernetes_endpoints_v1.api[0]
    values = {
      subset = [{
        address = [{ ip = "10.0.0.2" }]
        port    = [{ port = 443, protocol = "TCP" }]
      }]
    }
  }

  assert {
    condition = (
      length(kubernetes_role_v1.kagent_getter) == 5 &&
      length(kubernetes_role_v1.kagent_writer) == 5 &&
      length(kubernetes_role_v1.kagent_leader_election) == 2 &&
      length(kubernetes_role_v1.kagent_env_sources) == 5
    )
    error_message = "Bootstrap must create additive kagent permissions for both control planes, both declarative agent namespaces, and the prod migration namespace."
  }

  assert {
    condition = (
      output.kagent_rbac_targets["prod/migration-legacy"].namespace == "kagent-testbed" &&
      output.kagent_rbac_targets["prod/migration-legacy"].controller_namespace == "kagent-system" &&
      output.kagent_rbac_targets["prod/migration-legacy"].migration_only &&
      !contains(keys(output.kagent_rbac_targets), "dev/migration-legacy") &&
      kubernetes_role_v1.kagent_getter["prod/migration-legacy"].metadata[0].namespace == "kagent-testbed" &&
      kubernetes_role_v1.kagent_writer["prod/migration-legacy"].metadata[0].namespace == "kagent-testbed" &&
      kubernetes_role_v1.kagent_env_sources["prod/migration-legacy"].metadata[0].namespace == "kagent-testbed"
    )
    error_message = "The live kagent-testbed namespace must receive an explicit prod-only migration RBAC bridge."
  }

  assert {
    condition = (
      kubernetes_role_v1.kagent_getter["prod/control"].metadata[0].name == "kagent-control-plane-getter" &&
      kubernetes_role_binding_v1.kagent_getter["prod/control"].metadata[0].name == "kagent-control-plane-getter-binding" &&
      kubernetes_role_v1.kagent_writer["dev/codex"].metadata[0].name == "kagent-control-plane-writer" &&
      kubernetes_role_binding_v1.kagent_writer["dev/codex"].metadata[0].name == "kagent-control-plane-writer-binding" &&
      kubernetes_role_v1.kagent_leader_election["prod"].metadata[0].name == "kagent-control-plane-leader-election" &&
      kubernetes_role_binding_v1.kagent_leader_election["dev"].metadata[0].name == "kagent-control-plane-leader-election-binding" &&
      kubernetes_role_v1.kagent_env_sources["prod/codex"].metadata[0].name == "kagent-substrate-env-source-reader" &&
      kubernetes_role_binding_v1.kagent_env_sources["prod/migration-legacy"].metadata[0].name == "kagent-substrate-env-source-reader-binding"
    )
    error_message = "kagent RBAC must use only the stable parallel names."
  }

  assert {
    condition = (
      kubernetes_cluster_role_v1.substrate_api[0].metadata[0].name == "substrate-api-server-reader" &&
      kubernetes_cluster_role_binding_v1.substrate_api[0].metadata[0].name == "substrate-api-server-reader-binding" &&
      kubernetes_cluster_role_v1.substrate_controller[0].metadata[0].name == "substrate-controller-actortemplate" &&
      kubernetes_cluster_role_binding_v1.substrate_controller[0].metadata[0].name == "substrate-controller-actortemplate-binding"
    )
    error_message = "Substrate RBAC must use only the stable parallel names."
  }

  assert {
    condition = (
      kubernetes_role_binding_v1.kagent_getter["prod/control"].subject[0].name == "kagent-controller" &&
      kubernetes_role_binding_v1.kagent_writer["dev/codex"].subject[0].name == "kagent-controller" &&
      kubernetes_role_binding_v1.kagent_leader_election["dev"].subject[0].name == "kagent-controller" &&
      kubernetes_role_binding_v1.kagent_getter["prod/migration-legacy"].subject[0].namespace == "kagent-system" &&
      kubernetes_role_binding_v1.kagent_env_sources["prod/migration-legacy"].subject[0].name == "ate-api-server" &&
      kubernetes_cluster_role_binding_v1.substrate_api[0].subject[0].name == "ate-api-server" &&
      kubernetes_cluster_role_binding_v1.substrate_controller[0].subject[0].name == "ate-controller"
    )
    error_message = "Parallel RBAC must preserve every existing service-account subject."
  }

  assert {
    condition = (
      toset(one([
        for rule in kubernetes_role_v1.kagent_getter["prod/migration-legacy"].rule : rule.resources
        if toset(rule.api_groups) == toset(["kagent.dev"]) && toset(rule.verbs) == toset(["get", "list", "watch"])
      ])) == toset(["agents", "harnesses", "agenttemplates", "sandboxagents", "agentharnesses", "modelconfigs", "modelproviderconfigs", "toolservers", "memories", "remotemcpservers", "mcpservers"]) &&
      toset(one([
        for rule in kubernetes_role_v1.kagent_getter["prod/migration-legacy"].rule : rule.resources
        if toset(rule.api_groups) == toset(["kagent.dev"]) && toset(rule.verbs) == toset(["update"])
      ])) == toset(["agents/finalizers", "harnesses/finalizers", "agenttemplates/finalizers", "sandboxagents/finalizers", "agentharnesses/finalizers", "modelconfigs/finalizers", "modelproviderconfigs/finalizers", "toolservers/finalizers", "memories/finalizers", "remotemcpservers/finalizers", "mcpservers/finalizers"]) &&
      toset(one([
        for rule in kubernetes_role_v1.kagent_getter["prod/migration-legacy"].rule : rule.resources
        if toset(rule.api_groups) == toset(["kagent.dev"]) && toset(rule.verbs) == toset(["get", "patch", "update"])
      ])) == toset(["agents/status", "harnesses/status", "agenttemplates/status", "sandboxagents/status", "agentharnesses/status", "modelconfigs/status", "modelproviderconfigs/status", "toolservers/status", "memories/status", "remotemcpservers/status", "mcpservers/status"])
    )
    error_message = "Getter RBAC must be the exact union of live 0.9.12 agents permissions and the kap2 kagent.dev resources."
  }

  assert {
    condition = (
      toset(one([
        for rule in kubernetes_role_v1.kagent_writer["prod/migration-legacy"].rule : rule.resources
        if toset(rule.api_groups) == toset(["kagent.dev"]) && toset(rule.verbs) == toset(["create", "update", "patch", "delete"])
      ])) == toset(["agents", "harnesses", "agenttemplates", "sandboxagents", "agentharnesses", "modelconfigs", "modelproviderconfigs", "toolservers", "memories", "remotemcpservers", "mcpservers"]) &&
      toset(one([
        for rule in kubernetes_role_v1.kagent_writer["prod/migration-legacy"].rule : rule.resources
        if toset(rule.api_groups) == toset(["kagent.dev"]) && toset(rule.verbs) == toset(["update"])
      ])) == toset(["agents/finalizers", "harnesses/finalizers", "agenttemplates/finalizers", "sandboxagents/finalizers", "agentharnesses/finalizers", "modelconfigs/finalizers", "modelproviderconfigs/finalizers", "toolservers/finalizers", "memories/finalizers", "remotemcpservers/finalizers", "mcpservers/finalizers"])
    )
    error_message = "Writer RBAC must be the exact union of live 0.9.12 agents permissions and the kap2 kagent.dev resources."
  }

  assert {
    condition = (
      alltrue([
        for role in values(kubernetes_role_v1.kagent_getter) :
        role.rule == kubernetes_role_v1.kagent_getter["prod/migration-legacy"].rule
      ]) &&
      alltrue([
        for role in values(kubernetes_role_v1.kagent_writer) :
        role.rule == kubernetes_role_v1.kagent_writer["prod/migration-legacy"].rule
      ]) &&
      alltrue([
        for role in values(kubernetes_role_v1.kagent_env_sources) :
        role.rule == kubernetes_role_v1.kagent_env_sources["prod/migration-legacy"].rule
      ])
    )
    error_message = "Every control, declarative agent, and migration namespace must receive identical getter, writer, and env-source permissions."
  }

  assert {
    condition = !anytrue([
      for name in concat(values(output.rbac_names.kagent), values(output.rbac_names.substrate)) :
      startswith(name, "yourown-")
    ])
    error_message = "Terraform-owned RBAC names must not use the yourown prefix."
  }
}
