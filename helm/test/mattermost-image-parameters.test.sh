#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="${script_dir}/mattermost-image-parameters.sh"
repository="europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost"
digest="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

expected="mattermost_dev_image=${repository}@${digest},mattermost_version=${digest}"
actual="$(bash "${generator}" "${repository}" "${digest}")"
[[ "${actual}" == "${expected}" ]] || {
  printf 'expected %s, got %s\n' "${expected}" "${actual}" >&2
  exit 1
}

if bash "${generator}" "${repository}:mutable" "${digest}" >/dev/null 2>&1; then
  printf 'expected tagged repository to be rejected\n' >&2
  exit 1
fi

if bash "${generator}" "${repository}" "sha256:short" >/dev/null 2>&1; then
  printf 'expected truncated digest to be rejected\n' >&2
  exit 1
fi

printf 'Mattermost image parameter tests passed\n'
