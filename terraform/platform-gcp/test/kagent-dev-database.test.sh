#!/usr/bin/env bash

set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
inputs="${platform_dir}/service-inputs.tfdeploy.hcl"
components="${platform_dir}/components.tfcomponent.hcl"

fail() {
  printf 'kagent dev database contract failed: %s\n' "$*" >&2
  exit 1
}

block="$(sed -n '/    kagent_dev = {/,/^    }/p' "${inputs}")"
grep -Fq 'database_names       = ["kagent_dev"]' <<<"${block}" || fail 'dev database must be distinct from prod'
grep -Fq 'password_secret_id   = "kagent-dev-db-password"' <<<"${block}" || fail 'dev password secret missing'
grep -Fq 'connection_secret_id = "kagent-dev-database-url"' <<<"${block}" || fail 'dev connection secret missing'
grep -Fq 'namespace       = "kagent-dev"' <<<"${block}" || fail 'dev accessor namespace missing'
grep -Fq 'service_account = "kagent-controller"' <<<"${block}" || fail 'dev controller accessor missing'

grep -Fq 'for user_name, settings in var.additional_database_users' "${components}" ||
  fail 'service-owned database requests must flow through the generic Cloud SQL contract'
grep -Fq 'settings.kubernetes_connection_secret_accessors' "${components}" ||
  fail 'Kubernetes principal accessors must remain keyless Workload Identity principals'

printf 'kagent dev database contracts passed\n'
