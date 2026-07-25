#!/usr/bin/env bash
set -euo pipefail

changed_files="${1:?usage: route-components.sh CHANGED_FILES COMPONENT}"
component="${2:?usage: route-components.sh CHANGED_FILES COMPONENT}"

case "${component}" in
  mattermost)
    regex='^helm/(skaffold-mattermost\.yaml$|mattermost/|matterbridge/)'
    ;;
  mcp)
    regex='^(helm/(skaffold-mcp\.yaml$|mcp/)|docker/)'
    ;;
  *)
    printf 'Unknown release component: %s\n' "${component}" >&2
    exit 2
    ;;
esac

if grep -Eq "${regex}" "${changed_files}"; then
  printf 'true\n'
else
  printf 'false\n'
fi
