#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
catalog="${IMAGE_CATALOG:-${script_dir}/images.tsv}"
prepared_context_root="${PREPARED_CONTEXT_ROOT:-/workspace/image-sources}"

# shellcheck source=mcp/upstreams.env
source "${script_dir}/mcp/upstreams.env"

mkdir -p "${prepared_context_root}"

while IFS=$'\t' read -r name artifact_path kind dockerfile context parent_arg parent source_env change_regex audit deploy_parameter source description repository_env revision_env version_env; do
  [[ -z "${name}" || "${name}" == \#* || "${repository_env}" == "-" ]] && continue

  repository="${!repository_env}"
  revision="${!revision_env}"
  destination="${prepared_context_root}/${name}"

  printf 'Preparing %s from %s at %s\n' "${name}" "${repository}" "${revision}"
  git init "${destination}"
  git -C "${destination}" fetch --depth=1 "${repository}" "${revision}"
  git -C "${destination}" checkout --detach "${revision}"
done < "${catalog}"
