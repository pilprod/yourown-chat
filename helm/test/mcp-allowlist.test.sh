#!/usr/bin/env bash
set -euo pipefail

# The Terraform Stacks MCP is policy-constrained by environment allowlists.
# This public test pins the *shape* of those guardrails and their fidelity
# between the committed values and the rendered production Deployment. It
# deliberately names no private component or repository: the approved entries
# live in helm/mcp/values.yaml (and their private sources), not in this test.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
values_file="${repo_root}/helm/mcp/values.yaml"
render_file="$(mktemp)"
trap 'rm -f "${render_file}"' EXIT

helm template mcp "${repo_root}/helm/mcp" \
  --namespace mcp-terraform-stacks \
  --set mcp_terraform_stacks_image=example.invalid/terraform-stacks@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mcp_google_cloud_image=example.invalid/google-cloud@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mcp_tunnel_image=example.invalid/cloudflared@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mcp_secret_project=test \
  --set mcp_google_cloud_gsa=google-cloud@example.invalid \
  --set mcp_terraform_stacks_gsa=terraform-stacks@example.invalid \
  --set mcp_tunnel_gsa=tunnel@example.invalid > "${render_file}"

rendered_env() {
  # Prints the rendered value of one container environment variable.
  awk -v name="$1" '
    $1 == "-" && $2 == "name:" && $3 == name { found = 1; next }
    found && $1 == "value:" { sub(/^[^:]*:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }
  ' "${render_file}"
}

committed_env() {
  # Prints the committed value of one terraform-stacks env entry in values.yaml.
  awk -v key="$1:" '$1 == key { $1 = ""; sub(/^[[:space:]]+/, ""); gsub(/^"|"$/, ""); print; exit }' "${values_file}"
}

# Every guardrail variable is committed, rendered, and rendered exactly once.
for name in TFE_STACK_ALLOWLIST TFE_STACK_PROJECT_ALLOWLIST TFE_STACK_REPOSITORY_ALLOWLIST \
  TFE_STACK_DIRECTORY_PREFIX_ALLOWLIST TFE_STACK_GITHUB_APP_INSTALLATION_ID; do
  committed="$(committed_env "${name}")"
  rendered="$(rendered_env "${name}")"
  [[ -n "${committed}" ]] || { echo "${name} is not committed in values.yaml" >&2; exit 1; }
  [[ "${rendered}" == "${committed}" ]] || { echo "${name} rendered '${rendered}' != committed '${committed}'" >&2; exit 1; }
  [[ "$(grep -Fc "name: ${name}" "${render_file}")" == 1 ]] || { echo "${name} must render exactly once" >&2; exit 1; }
done

# Stack names: non-empty kebab-case identifiers, no wildcards, no duplicates.
stacks="$(rendered_env TFE_STACK_ALLOWLIST)"
[[ "${stacks}" =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]
[[ "$(tr ',' '\n' <<<"${stacks}" | sort | uniq -d | wc -l | tr -d ' ')" == 0 ]]

# Repositories: exact owner/name entries only, no wildcards, no duplicates, and
# the public platform repository that hosts the public Stacks is always allowed.
repos="$(rendered_env TFE_STACK_REPOSITORY_ALLOWLIST)"
[[ "${repos}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)*$ ]]
[[ "$(tr ',' '\n' <<<"${repos}" | sort | uniq -d | wc -l | tr -d ' ')" == 0 ]]
tr ',' '\n' <<<"${repos}" | grep -Fxq 'pilprod/yourown-chat'

# Remaining guardrails keep their committed shape.
[[ "$(rendered_env TFE_STACK_PROJECT_ALLOWLIST)" =~ ^prj-[A-Za-z0-9]+$ ]]
[[ "$(rendered_env TFE_STACK_DIRECTORY_PREFIX_ALLOWLIST)" == "terraform/" ]]
[[ "$(rendered_env TFE_STACK_GITHUB_APP_INSTALLATION_ID)" =~ ^ghain-[A-Za-z0-9]+$ ]]

# Documentation stays equal to the deployed policy: every allowlisted Stack
# name and repository appears in the Terraform MCP guardrail section of the
# runbook (docs/MCP.md), so operators never see a narrower boundary.
doc_section="$(awk '/^The adapter separates \*\*Stack management\*\*/,/^Available management tools:/' "${repo_root}/docs/MCP.md")"
while IFS= read -r name; do
  grep -Fq "\`${name}\`" <<<"${doc_section}" || { echo "docs/MCP.md does not document allowlisted Stack ${name}" >&2; exit 1; }
done < <(tr ',' '\n' <<<"${stacks}")
while IFS= read -r repo; do
  grep -Fq "\`${repo}\`" <<<"${doc_section}" || { echo "docs/MCP.md does not document allowlisted repository ${repo}" >&2; exit 1; }
done < <(tr ',' '\n' <<<"${repos}")

printf 'Terraform MCP allowlist rendering tests passed\n'
