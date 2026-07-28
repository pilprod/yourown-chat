#!/usr/bin/env bash
set -euo pipefail

source_ref="${1:?usage: mattermost-release-id.sh SOURCE_REF COMMIT_SHA BUILD_ID}"
commit_sha="${2:?usage: mattermost-release-id.sh SOURCE_REF COMMIT_SHA BUILD_ID}"
build_id="${3:-}"

slug() {
  printf '%s' "${1}" |
    tr '[:upper:]' '[:lower:]' |
    tr -c '[:alnum:]' '-' |
    sed -E 's/^-+//; s/-+$//; s/-+/-/g'
}

case "${source_ref}" in
  refs/heads/release-* | release-*)
    image_version="$(printf '%s' "${source_ref}" | sed -E 's|^refs/heads/||; s/^release-//')"
    ;;
  *)
    image_version="$(printf '%s' "${source_ref}" | sed -E 's/^v//; s/-patched$//')"
    ;;
esac
image_slug="$(slug "${image_version}")"
[ -n "${image_slug}" ] || {
  printf 'Mattermost source ref does not contain a usable version: %s\n' \
    "${source_ref}" >&2
  exit 2
}

[[ "${commit_sha}" =~ ^[[:xdigit:]]{8,64}$ ]] || {
  printf 'Mattermost source commit must be an 8-64 character hex SHA: %s\n' \
    "${commit_sha}" >&2
  exit 2
}
short_commit="$(printf '%s' "${commit_sha}" | tr '[:upper:]' '[:lower:]' | cut -c1-8)"

short_build="$(slug "${build_id}" | cut -c1-8)"
identity="${image_slug}-img-${short_commit}"

# Cloud Deploy derives rollout IDs by appending the target suffix. Production
# is one character longer than development, so validate against it.
rollout_suffix="-to-mattermost-prod-0001"
max_release_length=$((63 - ${#rollout_suffix}))
release_id="mattermost-${identity}"

if [[ -n "${short_build}" ]]; then
  release_with_build="${release_id}-${short_build}"
  if ((${#release_with_build} <= max_release_length)); then
    release_id="${release_with_build}"
  fi
fi

# If the readable prefix and source commit still exceed the limit, shorten the
# prefix first and then the image version. The commit identity is never dropped.
if ((${#release_id} > max_release_length)); then
  release_id="mm-${identity}"
fi

if ((${#release_id} > max_release_length)); then
  fixed_length=$((3 + 5 + ${#short_commit}))
  readable_length=$((max_release_length - fixed_length))
  ((readable_length > 0)) || {
    printf 'Mattermost release ID cannot retain the source commit\n' >&2
    exit 2
  }
  readable_version="$(
    printf '%s' "${image_slug}" |
      cut -c1-"${readable_length}" |
      sed -E 's/-+$//'
  )"
  release_id="mm-${readable_version}-img-${short_commit}"
fi

printf '%s\n' "${release_id}"
