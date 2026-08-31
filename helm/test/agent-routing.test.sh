#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
changed="$(mktemp)"
trap 'rm -f "${changed}"' EXIT

printf '%s\n' 'helm/yourown-chat/templates/deployments.yaml' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" yourown-chat)" == true ]]
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" mcp)" == false ]]
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" mattermost)" == false ]]

printf '%s\n' 'helm/kagent/kagent.values.yaml' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" kagent-substrate)" == true ]]

printf '%s\n' 'terraform/app-gcp/service-inputs.tfdeploy.hcl' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" kagent-substrate)" == true ]]

printf '%s\n' 'terraform/app-gcp/components.tfcomponent.hcl' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" kagent-substrate)" == false ]]

grep -Fq 'kagent-substrate=kagent-substrate-testbed' "${repo_root}/helm/mcp/values.yaml"

# The former worker release rail is removed rather than hidden behind a flag.
! find "${repo_root}/helm/agent-platform" -type f -print -quit 2>/dev/null | grep -q .
test ! -e "${repo_root}/helm/skaffold-agents.yaml"
test ! -e "${repo_root}/helm/agent-pilot.sh"
if bash "${repo_root}/helm/route-components.sh" "${changed}" agents >/dev/null 2>&1; then
  printf 'retired agents release component is still routable\n' >&2
  exit 1
fi

# Temporal is Terraform-owned composition over project-wide generic modules;
# it must never re-enter the application Cloud Deploy release.
test -f "${repo_root}/terraform/platform-gcp/modules/temporal/main.tf"
test -f "${repo_root}/terraform/platform-gcp/modules/cloudsql/main.tf"
test -f "${repo_root}/terraform/platform-gcp/modules/storage/main.tf"
grep -Fq 'component "temporal"' "${repo_root}/terraform/platform-gcp/components.tfcomponent.hcl"
grep -Fq 'component "cloudsql"' "${repo_root}/terraform/platform-gcp/components.tfcomponent.hcl"
! find "${repo_root}/terraform" -type d \( -name temporal-storage -o -name temporal-runtime \) -print -quit | grep -q .

printf 'Release routing tests passed\n'
