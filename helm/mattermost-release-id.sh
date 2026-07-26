#!/usr/bin/env bash
set -euo pipefail

image_tag="${1:?usage: mattermost-release-id.sh IMAGE_TAG}"

slug() {
  printf '%s' "${1}" |
    tr '[:upper:]' '[:lower:]' |
    tr -c '[:alnum:]' '-' |
    sed -E 's/^-+//; s/-+$//; s/-+/-/g'
}

image_version="$(
  printf '%s' "${image_tag}" |
    sed -E 's/^v//; s/-patched$//'
)"
image_slug="$(slug "${image_version}")"
[ -n "${image_slug}" ] || {
  printf 'Mattermost image tag does not contain a usable version: %s\n' \
    "${image_tag}" >&2
  exit 2
}

identity="${image_slug}-img"

# Cloud Deploy derives rollout IDs by appending the target suffix. Production
# is one character longer than development, so validate against it.
rollout_suffix="-to-mattermost-prod-0001"
max_release_length=$((63 - ${#rollout_suffix}))
release_id="mattermost-${identity}"

if ((${#release_id} > max_release_length)); then
  release_id="mm-${identity}"
fi

# Extremely long but valid source tags can still exceed the limit after the
# prefix fallback. Retain a readable prefix plus a deterministic identity hash.
if ((${#release_id} > max_release_length)); then
  identity_hash="$(
    if command -v sha256sum >/dev/null 2>&1; then
      printf '%s' "${identity}" | sha256sum
    else
      printf '%s' "${identity}" | shasum -a 256
    fi |
      cut -c1-8
  )"
  readable_length=$((max_release_length - 3 - 1 - ${#identity_hash}))
  readable_identity="$(
    printf '%s' "${identity}" |
      cut -c1-"${readable_length}" |
      sed -E 's/-+$//'
  )"
  release_id="mm-${readable_identity}-${identity_hash}"
fi

printf '%s\n' "${release_id}"
