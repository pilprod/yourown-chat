#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
changed="$(mktemp)"
trap 'rm -f "${changed}"' EXIT

printf '%s\n' 'helm/agent-platform/templates/deployments.yaml' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" agents)" == true ]]
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" mcp)" == false ]]
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" mattermost)" == false ]]

printf '%s\n' 'helm/yourown-chat/templates/deployments.yaml' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" yourown-chat)" == true ]]
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" agents)" == false ]]

printf '%s\n' 'terraform/components/temporal/main.tf' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" agents)" == false ]]

printf '%s\n' 'docker/base/node.Dockerfile' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" agents)" == false ]]

printf '%s\n' 'docker/images.tsv' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" agents)" == false ]]

printf '%s\n' 'docs/AGENT_PLATFORM.md' > "${changed}"
[[ "$(bash "${repo_root}/helm/route-components.sh" "${changed}" agents)" == false ]]

grep -Fq 'cloud_release agents-start start' "${repo_root}/helm/agent-pilot.sh"
grep -Fq 'cloud_release agents-pause pause' "${repo_root}/helm/agent-pilot.sh"
! grep -Fq 'agent_runtime_enabled=' "${repo_root}/helm/agent-pilot.sh"
grep -Fq 'yourown_chat_control_api_image=' "${repo_root}/helm/agent-pilot.sh"
grep -Fq 'yourown_chat_workflow_worker_image=' "${repo_root}/helm/agent-pilot.sh"
grep -Fq 'yourown_chat_activity_worker_image=' "${repo_root}/helm/agent-pilot.sh"
! grep -Fq 'yourown_chat_server_image=' "${repo_root}/helm/agent-pilot.sh"
grep -Fq 'agents-start=agents-start-pilot' "${repo_root}/helm/mcp/values.yaml"
grep -Fq 'agents-pause=agents-pause-pilot' "${repo_root}/helm/mcp/values.yaml"

# Temporal is Terraform-owned composition over project-wide generic modules;
# it must never re-enter the application Cloud Deploy release.
test -f "${repo_root}/terraform/platform-gcp/modules/temporal/main.tf"
test -f "${repo_root}/terraform/platform-gcp/modules/cloudsql/main.tf"
test -f "${repo_root}/terraform/platform-gcp/modules/storage/main.tf"
grep -Fq 'component "temporal"' "${repo_root}/terraform/platform-gcp/components.tfcomponent.hcl"
grep -Fq 'component "cloudsql"' "${repo_root}/terraform/platform-gcp/components.tfcomponent.hcl"
! find "${repo_root}/terraform" -type d \( -name temporal-storage -o -name temporal-runtime \) -print -quit | grep -q .
! grep -Fq 'temporal' "${repo_root}/helm/skaffold-agents.yaml"

printf 'Agent release routing tests passed\n'
