#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="${script_dir}/mattermost-release-id.sh"
rollout_suffix="-to-mattermost-prod-0001"

assert_id() {
  expected="${1}"
  shift
  actual="$(bash "${generator}" "$@")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected %s, got %s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
  if ((${#actual} + ${#rollout_suffix} > 63)); then
    printf 'release ID produces an oversized rollout: %s\n' "${actual}" >&2
    exit 1
  fi
}

assert_id "mattermost-11-9-0-img" "v11.9.0-patched"
assert_id "mattermost-11-10-12-img" "v11.10.12-patched"

long_id="$(
  bash "${generator}" \
    "v123456789.123456789.123456789-patched"
)"
[[ "${long_id}" == mm-* ]] || {
  printf 'expected mm- prefix fallback, got %s\n' "${long_id}" >&2
  exit 1
}
((${#long_id} + ${#rollout_suffix} <= 63))

printf 'Mattermost release ID tests passed\n'
