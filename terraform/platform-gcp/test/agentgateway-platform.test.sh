#!/usr/bin/env bash
set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
module="${platform_dir}/modules/agentgateway/main.tf"
asset="${platform_dir}/modules/agentgateway/files/gateway-api-v1.6.0-standard-install.yaml"
network="${platform_dir}/modules/network/main.tf"
expected_sha="a557172e8348f758479e9ee4000bbbb4b4aa48302a6b73461823ea5349bad56d"

fail() { printf 'agentgateway platform test failed: %s\n' "$*" >&2; exit 1; }
require_literal() { grep -Fq -- "$2" "$1" || fail "$1 is missing: $2"; }

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha="$(sha256sum "${asset}" | awk '{print $1}')"
else
  actual_sha="$(shasum -a 256 "${asset}" | awk '{print $1}')"
fi
[[ "${actual_sha}" == "${expected_sha}" ]] || fail "Gateway API asset checksum mismatch"

awk '
  /^  name: tlsroutes\.gateway\.networking\.k8s\.io$/ { in_tlsroute = 1 }
  in_tlsroute && /^    name: v1$/ { has_v1 = 1 }
  in_tlsroute && /^    served: true$/ { has_served = 1 }
  in_tlsroute && /^---$/ { exit !(has_v1 && has_served) }
  END { if (!in_tlsroute || !has_v1 || !has_served) exit 1 }
' "${asset}" || fail "vendored standard bundle lacks a served TLSRoute v1"

require_literal "${module}" 'gatewayNamespaces = [var.namespace]'
require_literal "${module}" 'create = false'
require_literal "${module}" 'if var.enabled'
if grep -Fq 'var.enabled ? local.gateway_api_manifests : {}' "${module}"; then
  fail "Gateway API manifest for_each must not use an object-incompatible conditional"
fi
require_literal "${module}" 'type = "RuntimeDefault"'
require_literal "${module}" 'sha256:9216ce83965ad2ce0888014d14aac5e71333fd9d4057cd167da92b37630fbee1'
require_literal "${module}" 'sha256:3a6cf44559c612ac8afb7f867aace69bbd4cdba765f1def6377b7a3186c603e3'
require_literal "${module}" 'sha256:319489cb86b7f901a52a3fc532ad07f136c92756f88cf02a4040909e20001120'
require_literal "${module}" 'sha256:bf2f339ef326d32def2aaeb44b1b4549801293c19b89e764a4228667d97d9896'
if grep -Eq 'kagent-testbed|ate-system' "${module}"; then
  fail "platform module must not bind application namespaces"
fi

require_literal "${network}" 'resource "google_compute_address" "agentgateway"'
require_literal "${network}" 'prevent_destroy = true'

printf 'agentgateway platform ownership tests passed\n'
