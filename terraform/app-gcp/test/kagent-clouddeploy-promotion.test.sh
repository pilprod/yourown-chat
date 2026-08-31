#!/usr/bin/env bash

set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
components="${app_dir}/components.tfcomponent.hcl"
release="${app_dir}/modules/deploy-release/main.tf"
mcp_values="${app_dir}/../../helm/mcp/values.yaml"

fail() {
  printf 'kagent Cloud Deploy promotion contract failed: %s\n' "$*" >&2
  exit 1
}

pipeline_block="$(sed -n '/component "clouddeploy_kagent_substrate" {/,/^}/p' "${components}")"
dev_line="$(grep -n 'name             = "dev"' <<<"${pipeline_block}" | cut -d: -f1)"
prod_line="$(grep -n 'name             = "prod"' <<<"${pipeline_block}" | cut -d: -f1)"
[[ -n "${dev_line}" && -n "${prod_line}" && "${dev_line}" -lt "${prod_line}" ]] ||
  fail 'stages must be ordered dev then prod'

grep -Fq 'profiles         = ["kagent-dev"]' <<<"${pipeline_block}" || fail 'dev profile missing'
grep -Fq 'require_approval = false' <<<"${pipeline_block}" || fail 'dev must deploy without approval'
grep -Fq 'profiles         = ["kagent-prod"]' <<<"${pipeline_block}" || fail 'prod profile missing'
grep -Fq 'require_approval = true' <<<"${pipeline_block}" || fail 'prod must require approval'
[[ "$(grep -Fc 'predeploy_actions = ["require-external-broker-smoke"]' <<<"${pipeline_block}")" -eq 1 ]] ||
  fail 'prod must have exactly one external Broker smoke predeploy gate'
predeploy_line="$(grep -Fn 'predeploy_actions = ["require-external-broker-smoke"]' <<<"${pipeline_block}" | cut -d: -f1)"
[[ "${predeploy_line}" -gt "${prod_line}" ]] || fail 'external Broker smoke gate must be attached only to prod'
[[ "$(grep -Fc 'verify           = true' <<<"${pipeline_block}")" -eq 2 ]] ||
  fail 'both stages must verify'

grep -Fq 'kagent-substrate=kagent-substrate-dev|kagent-substrate-prod' "${mcp_values}" ||
  fail 'Google Cloud MCP target allowlist must expose both promotion targets'

release_block="$(sed -n '/if \[ "${try(var.kagent_substrate_delivery.release_enabled, false)}" = "true" \]/,/^          fi$/p' "${release}")"
[[ "$(grep -Fc 'create_release \' <<<"${release_block}")" -eq 1 ]] ||
  fail 'one source tag must create exactly one Cloud Deploy release'
grep -Fq 'production-eligible=true,promotion=dev-to-approved-prod' <<<"${release_block}" ||
  fail 'release annotations must preserve the promotion contract'
if grep -Eq 'docker (build|buildx)|gcloud builds submit|:latest' <<<"${release_block}"; then
  fail 'promotion must not rebuild images or admit latest'
fi

printf 'kagent Cloud Deploy promotion contracts passed\n'
