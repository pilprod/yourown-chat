#!/usr/bin/env bash
set -euo pipefail

changed_files="${1:?usage: route-components.sh CHANGED_FILES COMPONENT [BASELINE_REF]}"
component="${2:?usage: route-components.sh CHANGED_FILES COMPONENT [BASELINE_REF]}"
baseline_ref="${3:-}"

case "${component}" in
  mattermost)
    # Chart.appVersion is stamped from the readable source tag inside the
    # Mattermost image-triggered release; deployment parameters carry the
    # immutable digest. Chart.yaml metadata alone must not start a second
    # Mattermost release from the platform semver tag.
    workload_regex='^helm/(mattermost/(templates/|values[^/]*\.yaml$|verify/|rtcd/)|matterbridge/)'
    config_path='helm/skaffold-mattermost.yaml'
    ;;
  mcp)
    workload_regex='^helm/mcp/'
    config_path='helm/skaffold-mcp.yaml'
    ;;
  agents)
    workload_regex='^helm/agent-platform/'
    config_path='helm/skaffold-agents.yaml'
    ;;
  yourown-chat)
    workload_regex='^helm/yourown-chat/'
    config_path='helm/skaffold-yourown-chat.yaml'
    ;;
  *)
    printf 'Unknown release component: %s\n' "${component}" >&2
    exit 2
    ;;
esac

if grep -Eq "${workload_regex}" "${changed_files}"; then
  printf 'true\n'
elif grep -Fxq "${config_path}" "${changed_files}"; then
  # The first split of the former shared skaffold.yaml is a routing migration,
  # not a Mattermost workload change. Suppress that one baseline addition;
  # subsequent edits route normally because the component file then exists in
  # the preceding semver tag. Initial releases (no baseline) still route.
  if [[ -n "${baseline_ref}" ]] &&
    ! git cat-file -e "${baseline_ref}:${config_path}" 2>/dev/null; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
else
  printf 'false\n'
fi
