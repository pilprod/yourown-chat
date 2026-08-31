#!/usr/bin/env bash

set -euo pipefail

platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
components="${platform_dir}/components.tfcomponent.hcl"

fail() {
  printf 'Cloud Build Pub/Sub prerequisite test failed: %s\n' "$*" >&2
  exit 1
}

grep -Fq '"pubsub.googleapis.com"' "${components}" ||
  fail "platform must enable the Pub/Sub API for app-owned release triggers"
grep -Fq 'app-gcp owns the source-less release trigger and its topic' "${components}" ||
  fail "platform must document app ownership of the source-less trigger and topic"

if grep -R -E 'resource "google_(pubsub_topic|cloudbuild_trigger)"' \
  --include='*.tf' "${platform_dir}/modules" >/dev/null; then
  fail "Pub/Sub topics and Cloud Build triggers belong to app-gcp, not platform-gcp"
fi

printf 'Cloud Build Pub/Sub platform prerequisite checks passed\n'
