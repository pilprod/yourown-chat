#!/usr/bin/env bash

set -euo pipefail

release_tag="${1:-}"
project_id="${2:-yourown-chat}"
topic_name="${3:-kagent-preview-release}"

if [[ ! "${release_tag}" =~ ^gcp-v[0-9]+\.[0-9]+\.[0-9]+-external-slot\.kap\.[0-9]+$ ]]; then
  printf 'usage: %s gcp-vX.Y.Z-external-slot.kap.N [project] [topic]\n' "$0" >&2
  exit 2
fi

command -v gcloud >/dev/null 2>&1 || {
  printf 'required command is unavailable: gcloud\n' >&2
  exit 1
}

gcloud pubsub topics publish "${topic_name}" \
  --project="${project_id}" \
  --message='kagent immutable release request' \
  --attribute="releaseTag=${release_tag}"

printf 'submitted %s to projects/%s/topics/%s\n' \
  "${release_tag}" "${project_id}" "${topic_name}"
