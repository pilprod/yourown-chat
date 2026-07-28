#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/helm/mattermost-release-channel.sh"

assert_channel() {
  local expected="$1"
  local tag="$2"
  local actual
  actual="$("$script" "$tag")"
  [[ "$actual" == "$expected" ]] || {
    printf 'expected %s for %s, got %s\n' "$expected" "$tag" "$actual" >&2
    exit 1
  }
}

assert_rejected() {
  local tag="$1"
  if "$script" "$tag" >/dev/null 2>&1; then
    printf 'expected tag to be rejected: %s\n' "$tag" >&2
    exit 1
  fi
}

assert_channel production v11.9.0-patched
assert_channel production v11.10.12-patched
assert_channel experimental v11.9.0-dev.1
assert_channel experimental v11.9.0-dev.12

assert_rejected v11.9.0-product-dev.1
assert_rejected v11.9.0-dev
assert_rejected v11.9.0-patched.1
assert_rejected 11.9.0-dev.1

printf '%s\n' 'Mattermost release channel tests passed'
