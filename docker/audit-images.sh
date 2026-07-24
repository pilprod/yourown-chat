#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
catalog="${IMAGE_CATALOG:-${script_dir}/images.tsv}"
changed_files="${CHANGED_FILES:-/dev/null}"
force_audit="${FORCE_AUDIT:-false}"

if [[ "${force_audit}" != "true" ]] &&
  ! grep -Eq '^docker/' "${changed_files}"; then
  printf 'Docker inputs are unchanged; skipping language dependency audits\n'
  exit 0
fi

while IFS=$'\t' read -r name kind dockerfile context parent_arg parent source_env change_regex audit deploy_parameter source description repository_env revision_env version_env; do
  [[ -z "${name}" || "${name}" == \#* || "${audit}" == "-" ]] && continue

  case "${audit}" in
    npm)
      printf 'Auditing %s\n' "${name}"
      (
        cd "${repo_root}/${context}"
        npm audit --omit=dev --audit-level=high
      )
      ;;
    *)
      printf 'Unknown audit kind %s for %s\n' "${audit}" "${name}" >&2
      exit 1
      ;;
  esac
done < "${catalog}"
