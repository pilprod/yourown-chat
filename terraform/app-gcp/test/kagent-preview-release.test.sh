#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
repo_dir="$(cd "$app_dir/../.." && pwd)"

components="$app_dir/components.tfcomponent.hcl"
variables="$app_dir/variables.tfcomponent.hcl"
deployment="$app_dir/app.tfdeploy.hcl"
module="$app_dir/modules/kagent-preview-release/main.tf"
clouddeploy_module="$app_dir/modules/clouddeploy/main.tf"
clouddeploy_variables="$app_dir/modules/clouddeploy/variables.tf"
workload_scheduling="$app_dir/modules/workload-scheduling/main.tf"
cluster_bootstrap="$app_dir/modules/cluster-bootstrap/main.tf"
cloudflare_dir="$repo_dir/terraform/cloudflare"
cloudflare_components="$cloudflare_dir/components.tfcomponent.hcl"
cloudflare_variables="$cloudflare_dir/variables.tfcomponent.hcl"
cloudflare_deployment="$cloudflare_dir/cloudflare.tfdeploy.hcl"
cloudflare_outputs="$cloudflare_dir/outputs.tfcomponent.hcl"
mcp_values="$repo_dir/helm/mcp/values.yaml"
mcp_tunnel="$repo_dir/helm/mcp/templates/tunnel.yaml"

fail() {
  echo "kagent preview release test failed: $*" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local value="$2"
  rg -Fq -- "$value" "$file" || fail "$file is missing: $value"
}

require_regex() {
  local file="$1"
  local value="$2"
  rg -q -- "$value" "$file" || fail "$file does not match: $value"
}

pipeline_block="$(sed -n '/component "clouddeploy_kagent_preview"/,/component "clouddeploy_mcp"/p' "$components")"
trigger_block="$(sed -n '/resource "google_cloudbuild_trigger" "preview"/,$p' "$module")"

[[ "$pipeline_block" == *'pipeline_name           = "kagent-preview"'* ]] || fail "pipeline name drifted"
[[ "$pipeline_block" == *'name             = "testbed"'* ]] || fail "testbed is not the only authored stage"
[[ "$pipeline_block" == *'target_name      = "kagent-testbed"'* ]] || fail "target name drifted"
[[ "$pipeline_block" == *'profiles         = ["kagent-testbed"]'* ]] || fail "Skaffold profile drifted"
[[ "$pipeline_block" == *'require_approval = false'* ]] || fail "preview tag must remain the approval boundary"
[[ "$pipeline_block" == *'verify           = true'* ]] || fail "Cloud Deploy verification is disabled"
[[ "$pipeline_block" != *'name             = "prod"'* ]] || fail "preview pipeline must never contain a prod stage"
[[ "$pipeline_block" == *'"roles/container.clusterViewer"'* ]] || fail "preview execution needs read-only cluster discovery"
[[ "$pipeline_block" != *'"roles/container.developer"'* ]] || fail "container.developer would grant CRD write"
[[ "$pipeline_block" != *'"roles/storage.objectUser"'* ]] || fail "preview execution storage access must stay bucket-scoped"
[[ "$pipeline_block" != *'"roles/artifactregistry.reader"'* ]] || fail "preview execution registry access must stay repository-scoped"

[[ "$trigger_block" == *'filename        = var.cloudbuild_config_path'* ]] || fail "trigger must use repository-owned cloudbuild.preview.yaml"
[[ "$trigger_block" == *'tag = var.preview_tag_regex'* ]] || fail "trigger is not tag-only"
[[ "$trigger_block" != *'branch ='* ]] || fail "branch triggers are forbidden"

require_literal "$variables" 'default     = "^preview-[0-9]{8}-[1-9][0-9]*$"'
require_regex "$deployment" 'kagent_preview_tag_regex[[:space:]]*=[[:space:]]*"\^preview-\[0-9\]\{8\}-\[1-9\]\[0-9\]\*\$"'
require_literal "$deployment" 'kagent_testbed_enabled       = false'
require_literal "$deployment" 'kagent_preview_enabled       = true'
require_literal "$deployment" 'kagent_preview_crds_ready        = false'
require_literal "$deployment" 'kagent_preview_crd_bundle_sha256 = "b34b1165e642e5c621443550f8b212957f49ed9df77e36b87832ee7df51fe1f7"'
require_literal "$deployment" 'kagent_preview_substrate_ready   = false'
require_literal "$deployment" 'kagent_preview_substrate_version = "0.0.20"'
require_literal "$deployment" 'kagent_preview_ui_access_enabled = try(upstream_input.cloudflare.kagent_preview_ui_access_ready, false)'
require_literal "$components" 'var.kagent_preview_enabled || var.kagent_testbed_enabled ? {'
require_literal "$workload_scheduling" 'kagent_namespaces_enabled = var.kagent_preview_enabled || var.kagent_testbed_enabled'
require_literal "$workload_scheduling" 'resource "kubernetes_network_policy_v1" "kagent_preview_ui_ingress"'
require_literal "$workload_scheduling" 'resource "kubernetes_network_policy_v1" "cloudflared_to_kagent_preview_ui"'
require_literal "$workload_scheduling" 'resource "kubernetes_network_policy_v1" "kagent_preview_ui_verify_ingress"'
require_literal "$workload_scheduling" 'resource "kubernetes_network_policy_v1" "kagent_preview_verifier_egress"'
require_literal "$workload_scheduling" 'count = var.kagent_preview_enabled && var.kagent_preview_ui_access_enabled ? 1 : 0'
require_literal "$workload_scheduling" 'match_labels = { app = "mcp-tunnel" }'
require_literal "$workload_scheduling" 'match_labels = { "platform.yourown.chat/verify" = "kagent-preview" }'
require_literal "$workload_scheduling" '"app.kubernetes.io/component" = "ui"'
require_literal "$workload_scheduling" 'port     = "8080"'
require_literal "$workload_scheduling" 'port     = "8083"'
require_literal "$workload_scheduling" 'resources  = ["modelconfigs"]'
require_literal "$workload_scheduling" 'resources  = ["deployments"]'
require_literal "$workload_scheduling" 'resources  = ["replicasets"]'
require_literal "$workload_scheduling" 'resources  = ["jobs"]'
require_literal "$workload_scheduling" 'verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]'
require_literal "$workload_scheduling" 'name      = var.kagent_preview_execution_service_account_email'
require_literal "$workload_scheduling" 'name      = "kagent-preview-getter-role"'
require_literal "$workload_scheduling" 'name      = "kagent-preview-writer-role"'
require_literal "$workload_scheduling" 'name      = "kagent-preview-ate-api-env-sources"'
require_literal "$workload_scheduling" 'name      = var.kagent_preview_controller_service_account'
if rg -q 'verbs\s+=.*"bind"|verbs\s+=.*"escalate"' "$workload_scheduling"; then
  fail "preview identities must not receive bind or escalate"
fi
if rg -q 'kagent_preview_rbac_author' "$workload_scheduling"; then
  fail "Cloud Deploy must not author controller RBAC"
fi
if rg -qi 'customresourcedefinitions|clusterroles|clusterrolebindings' "$workload_scheduling"; then
  fail "preview execution must not receive cluster-scoped Kubernetes writes"
fi
require_literal "$module" '_PREVIEW_LOCK        = var.preview_lock_path'
require_literal "$module" '_CRDS_READY          = tostring(var.crds_ready)'
require_literal "$module" '_CRD_BUNDLE_SHA256   = var.crd_bundle_sha256'
require_literal "$module" '_SUBSTRATE_READY     = tostring(var.substrate_ready)'
require_literal "$module" '_SUBSTRATE_VERSION   = var.substrate_version'
require_literal "$module" '_EVIDENCE_BUCKET     = google_storage_bucket.source.name'
require_literal "$module" 'source_bucket_name       = "${var.project_id}-kagent-preview-${var.region}"'
require_literal "$module" 'role     = "roles/clouddeploy.releaser"'
require_literal "$module" 'role               = "roles/iam.serviceAccountUser"'
require_literal "$module" 'resource "google_storage_bucket_iam_member" "execution_source_objects"'
require_literal "$module" 'role   = "roles/storage.objectViewer"'
require_literal "$module" 'resource "google_artifact_registry_repository_iam_member" "execution_reader"'
require_literal "$module" 'member     = "serviceAccount:${var.execution_service_account_email}"'
require_literal "$clouddeploy_variables" 'target_name        = optional(string)'
require_literal "$clouddeploy_module" 'name             = coalesce(each.value.target_name, "${var.pipeline_name}-${each.value.name}")'

if rg -q 'resource "google_storage_bucket"' "$module"; then
  :
else
  fail "kagent preview evidence and release source require a dedicated bucket"
fi

if rg -q 'kagent_preview_enabled' "$cluster_bootstrap"; then
  fail "the preview gate must never enable Terraform-owned legacy Helm releases"
fi

require_literal "$cloudflare_variables" 'variable "kagent_preview_ui_access_enabled"'
require_literal "$cloudflare_variables" 'default     = false'
require_literal "$cloudflare_components" 'kagent-preview = "http://kagent-preview-ui.kagent-system.svc.cluster.local:8080"'
require_literal "$cloudflare_deployment" 'kagent_preview_ui_access_enabled = false'
require_literal "$cloudflare_deployment" 'publish_output "kagent_preview_ui_access_ready"'
require_literal "$cloudflare_outputs" 'output "kagent_preview_ui_access_ready"'
require_literal "$cloudflare_outputs" '"kagent-preview.${var.domain}"'
require_literal "$mcp_values" 'mcp_tunnel_image: ""'
require_literal "$mcp_values" 'secretName: mcp-tunnel-token'
require_literal "$mcp_tunnel" 'image: {{ required (printf "Cloud Deploy parameter %s is required" .) (get $.Values .) | quote }}'
require_literal "$mcp_tunnel" 'driver: secrets-store-gke.csi.k8s.io'
require_literal "$mcp_tunnel" '--no-autoupdate'

cloudflare_ui_block="$(sed -n '/kagent-preview = /,/} : {},/p' "$cloudflare_components")"
[[ "$cloudflare_ui_block" != *'public_upstreams'* ]] || fail "kagent UI must be Access-protected, not a public webhook upstream"

require_literal "$repo_dir/docs/KAGENT_PREVIEW_DELIVERY.md" 'Terraform owns only shared cluster prerequisites plus the pipeline, target,'
require_literal "$repo_dir/docs/KAGENT_PREVIEW_DELIVERY.md" 'The controller REST and A2A Gateway Services are not Tunnel origins'

echo "kagent preview release wiring: ok"
