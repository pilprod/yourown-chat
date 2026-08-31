#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'usage: %s 0.0.22-private.N\n' "$0" >&2
  exit 2
fi

readonly expected_release_version="0.0.22-private.1"
release_version="$1"
project_id="${GOOGLE_CLOUD_PROJECT:-yourown-chat}"

if [[ "${release_version}" != "${expected_release_version}" ]]; then
  printf 'release version must equal the currently applied coordinate %s: %s\n' \
    "${expected_release_version}" "${release_version}" >&2
  exit 2
fi

gcloud pubsub topics publish substrate-private-release \
  --project "${project_id}" \
  --attribute "releaseVersion=${release_version}" \
  --message "private Substrate release ${release_version}"
