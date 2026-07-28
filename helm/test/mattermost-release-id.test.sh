#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="${script_dir}/mattermost-release-id.sh"

assert_id() {
  expected="${1}"
  target="${2}"
  shift
  shift
  actual="$(bash "${generator}" "$@")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected %s, got %s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
  rollout_suffix="-to-${target}-0001"
  if ((${#actual} + ${#rollout_suffix} > 63)); then
    printf 'release ID produces an oversized rollout: %s\n' "${actual}" >&2
    exit 1
  fi
}

assert_id \
  "mm-11-9-patched-img-deadbeef" \
  "mattermost-preview-dev" \
  "release-11.9-patched" \
  "deadbeefcafebabe" \
  "12345678-1234-1234-1234-123456789abc" \
  "mattermost-preview-dev"

assert_id \
  "mattermost-11-9-0-img-deadbeef-12345678" \
  "mattermost-dev" \
  "v11.9.0-patched" \
  "deadbeefcafebabe" \
  "12345678-1234-1234-1234-123456789abc" \
  "mattermost-dev"

assert_id \
  "mm-11-10-patched-img-deadbeef" \
  "mattermost-preview-dev" \
  "refs/heads/release-11.10-patched" \
  "deadbeefcafebabe" \
  "12345678-1234-1234-1234-123456789abc" \
  "mattermost-preview-dev"

long_id="$(
  bash "${generator}" \
    "release-123456789.123456789-patched" \
    "deadbeefcafebabe" \
    "12345678-1234-1234-1234-123456789abc" \
    "mattermost-preview-dev"
)"
preview_rollout_suffix="-to-mattermost-preview-dev-0001"
[[ "${long_id}" == mm-* ]] || {
  printf 'expected mm- prefix fallback, got %s\n' "${long_id}" >&2
  exit 1
}
[[ "${long_id}" == *-img-deadbeef ]] || {
  printf 'expected source commit to be retained, got %s\n' "${long_id}" >&2
  exit 1
}
((${#long_id} + ${#preview_rollout_suffix} <= 63))

if bash "${generator}" "release-11.9-patched" "not-a-sha" "12345678" \
  >/dev/null 2>&1; then
  printf 'expected a non-SHA commit identity to be rejected\n' >&2
  exit 1
fi

printf 'Mattermost release ID tests passed\n'
