#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
catalog="${IMAGE_CATALOG:-${script_dir}/images.tsv}"
output_dir="${OUTPUT_DIR:-/workspace}"

: "${AR_PREFIX:?AR_PREFIX must be set, for example europe-west3-docker.pkg.dev/project/docker}"

parameters=()

while IFS=$'\t' read -r name artifact_path kind dockerfile context parent_arg parent source_env change_regex audit deploy_parameter source description repository_env revision_env version_env; do
  [[ -z "${name}" || "${name}" == \#* || "${deploy_parameter}" == "-" ]] && continue

  repository="${AR_PREFIX}/${artifact_path}"
  built_image_file="${output_dir}/${name}-image"
  if [[ -s "${built_image_file}" ]]; then
    built_image="$(cat "${built_image_file}")"
    digest="$(gcloud artifacts docker images describe \
      "${built_image}" --format='value(image_summary.digest)')"
  else
    digest="$(gcloud artifacts docker images list "${repository}" \
      --sort-by='~UPDATE_TIME' \
      --limit=1 \
      --format='value(version)')"
  fi

  [[ -n "${digest}" ]] || {
    printf 'Internal image is missing for catalog entry %s\n' "${name}" >&2
    exit 1
  }
  parameters+=("${deploy_parameter}=${repository}@${digest}")
done < "${catalog}"

(
  IFS=,
  printf '%s\n' "${parameters[*]}"
)
