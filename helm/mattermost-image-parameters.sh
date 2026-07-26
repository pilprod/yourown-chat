#!/usr/bin/env bash
set -euo pipefail

image_repository="${1:?usage: mattermost-image-parameters.sh IMAGE_REPOSITORY IMAGE_DIGEST}"
image_digest="${2:?usage: mattermost-image-parameters.sh IMAGE_REPOSITORY IMAGE_DIGEST}"

if [[ "${image_repository}" == *":"* || "${image_repository}" == *"@"* ]]; then
  printf 'Mattermost image repository must not include a tag or digest: %s\n' \
    "${image_repository}" >&2
  exit 2
fi

if [[ ! "${image_digest}" =~ ^sha256:[[:xdigit:]]{64}$ ]]; then
  printf 'Mattermost image digest must be a complete sha256 digest: %s\n' \
    "${image_digest}" >&2
  exit 2
fi

# Dev consumes the complete immutable reference directly. The Mattermost
# Operator recognizes a sha256-prefixed spec.version and renders
# <spec.image>@<spec.version> for production.
printf 'mattermost_dev_image=%s@%s,mattermost_version=%s\n' \
  "${image_repository}" "${image_digest}" "${image_digest}"
