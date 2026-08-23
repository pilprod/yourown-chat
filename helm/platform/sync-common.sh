#!/usr/bin/env bash
# Copies the canonical platform helper template into every profile chart.
# The copies are generated artifacts: edit helm/platform/_common/_platform.tpl,
# run this script, and commit both. helm/test/platform-common.test.sh verifies
# that no copy has drifted from the source.
set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_file="${platform_dir}/_common/_platform.tpl"
mode="${1:-write}"
status=0

for chart in "${platform_dir}"/platform-*/; do
  target="${chart}templates/_platform.tpl"
  if [ "${mode}" = "check" ]; then
    if ! cmp -s "${source_file}" "${target}"; then
      echo "drift: ${target} differs from ${source_file}" >&2
      status=1
    fi
  else
    cp "${source_file}" "${target}"
    echo "synced ${target}"
  fi
done

exit "${status}"
