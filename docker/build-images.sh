#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
catalog="${IMAGE_CATALOG:-${script_dir}/images.tsv}"
changed_files="${CHANGED_FILES:-/dev/null}"
prepared_context_root="${PREPARED_CONTEXT_ROOT:-/workspace/image-sources}"

: "${AR_PREFIX:?AR_PREFIX must be set, for example europe-west3-docker.pkg.dev/project/docker}"
: "${IMAGE_TAG:?IMAGE_TAG must be set to an immutable build identifier}"

build_version="${BUILD_VERSION:-${IMAGE_TAG}}"
vcs_ref="${VCS_REF:-${IMAGE_TAG}}"
force_build="${FORCE_BUILD:-false}"
output_dir="${OUTPUT_DIR:-/workspace}"
changed_input="$(cat "${changed_files}")"

# shellcheck source=mcp/upstreams.env
source "${script_dir}/mcp/upstreams.env"

image_names=()
image_ref_values=()
rebuilt_values=()

set_image_state() {
  image_names+=("$1")
  image_ref_values+=("$2")
  rebuilt_values+=("$3")
}

get_image_ref() {
  local wanted="$1"
  local index
  for ((index = 0; index < ${#image_names[@]}; index++)); do
    if [[ "${image_names[${index}]}" == "${wanted}" ]]; then
      printf '%s' "${image_ref_values[${index}]}"
      return 0
    fi
  done
  return 1
}

was_rebuilt() {
  local wanted="$1"
  local index
  for ((index = 0; index < ${#image_names[@]}; index++)); do
    if [[ "${image_names[${index}]}" == "${wanted}" ]]; then
      [[ "${rebuilt_values[${index}]}" == "true" ]]
      return
    fi
  done
  return 1
}

changed() {
  local regex="$1"
  [[ "${force_build}" == "true" ]] || grep -Eq "${regex}" <<< "${changed_input}"
}

publish_runtime_tag() {
  local immutable_image="$1"
  local runtime_image="$2"
  docker tag "${immutable_image}" "${runtime_image}"
  docker push "${runtime_image}"
}

while IFS=$'\t' read -r name artifact_path kind dockerfile context parent_arg parent source_env change_regex audit deploy_parameter source description repository_env revision_env version_env; do
  [[ -z "${name}" || "${name}" == \#* ]] && continue

  repository="${AR_PREFIX}/${artifact_path}"
  immutable_image="${repository}:${IMAGE_TAG}"
  runtime_image="${repository}:runtime"
  should_build=false

  if changed "${change_regex}"; then
    should_build=true
  elif [[ "${parent}" != "-" ]] && was_rebuilt "${parent}"; then
    should_build=true
  elif ! docker pull "${runtime_image}" >/dev/null 2>&1; then
    # Bootstrap a catalog entry that has never been published.
    should_build=true
  fi

  if [[ "${should_build}" != "true" ]]; then
    resolved_image="$(docker image inspect \
      --format '{{index .RepoDigests 0}}' "${runtime_image}")"
    set_image_state "${name}" "${resolved_image:-${runtime_image}}" false
    printf 'Reusing %s\n' "${runtime_image}"
    continue
  fi

  if [[ "${kind}" == "mirror" ]]; then
    source_image="${!source_env}"
    docker pull "${source_image}"
    docker tag "${source_image}" "${immutable_image}"
  elif [[ "${kind}" == "build" ]]; then
    if [[ "${context}" == "@prepared" ]]; then
      build_context="${prepared_context_root}/${name}"
    else
      build_context="${repo_root}/${context}"
    fi
    [[ -d "${build_context}" ]] || {
      printf 'Build context does not exist: %s\n' "${build_context}" >&2
      exit 1
    }

    build_args=(
      --file "${repo_root}/${dockerfile}"
      --tag "${immutable_image}"
      --label "org.opencontainers.image.title=${name}"
      --label "org.opencontainers.image.description=${description}"
      --label "org.opencontainers.image.source=${source}"
    )
    image_vcs_ref="${vcs_ref}"
    image_build_version="${build_version}"
    [[ "${revision_env}" == "-" ]] || image_vcs_ref="${!revision_env}"
    [[ "${version_env}" == "-" ]] || image_build_version="${!version_env}"
    build_args+=(
      --label "org.opencontainers.image.revision=${image_vcs_ref}"
      --label "org.opencontainers.image.version=${image_build_version}"
    )
    if [[ "${parent}" != "-" ]]; then
      parent_image="$(get_image_ref "${parent}" || true)"
      [[ -n "${parent_image}" ]] || {
        printf 'Parent image %s was not resolved before %s\n' "${parent}" "${name}" >&2
        exit 1
      }
      build_args+=(--build-arg "${parent_arg}=${parent_image}")
    fi
    docker build "${build_args[@]}" "${build_context}"
  else
    printf 'Unknown image kind %s for %s\n' "${kind}" "${name}" >&2
    exit 1
  fi

  docker push "${immutable_image}"
  publish_runtime_tag "${immutable_image}" "${runtime_image}"
  printf '%s' "${immutable_image}" > "${output_dir}/${name}-image"
  set_image_state "${name}" "${immutable_image}" true
done < "${catalog}"
