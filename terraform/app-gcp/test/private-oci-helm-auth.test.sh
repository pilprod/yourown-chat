#!/usr/bin/env bash

set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
providers="${root_dir}/terraform/app-gcp/providers.tfcomponent.hcl"

fail() {
  printf 'private OCI Helm auth contract failed: %s\n' "$1" >&2
  exit 1
}

provider_block="$(sed -n '/provider "helm" "this" {/,/^}/p' "${providers}")"

for required in \
  'registries = [{' \
  'url      = "oci://${var.kagent_registry_location}-docker.pkg.dev"' \
  'username = "oauth2accesstoken"' \
  'password = component.gke_auth.access_token'; do
  grep -Fq -- "${required}" <<<"${provider_block}" ||
    fail "missing keyless registry contract: ${required}"
done

if grep -Eq 'url[[:space:]]*=[[:space:]]*"oci://[^"/]+/[^" ]+' <<<"${provider_block}"; then
  fail 'Helm registry URL must identify only the Artifact Registry host'
fi

if grep -Eqi '(service_account_key|credentials_file|password[[:space:]]*=[[:space:]]*var\.|registry_password|dockerconfigjson)' <<<"${provider_block}"; then
  fail 'Helm registry auth must not accept a static credential or registry password input'
fi

token_uses="$(grep -Fc 'component.gke_auth.access_token' <<<"${provider_block}")"
[[ "${token_uses}" -eq 2 ]] ||
  fail 'the same short-lived GKE token must authenticate Kubernetes and private OCI pulls'

printf 'private OCI Helm auth contracts passed\n'
