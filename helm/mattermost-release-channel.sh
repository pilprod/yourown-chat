#!/usr/bin/env bash

set -euo pipefail

tag="${1:-}"

if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-patched$ ]]; then
  printf '%s\n' production
elif [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$ ]]; then
  printf '%s\n' experimental
else
  printf 'unsupported Mattermost release tag: %s\n' "$tag" >&2
  exit 1
fi
