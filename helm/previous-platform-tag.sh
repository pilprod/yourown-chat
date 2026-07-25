#!/usr/bin/env bash
set -euo pipefail

commit="${1:?usage: previous-platform-tag.sh COMMIT}"

# Keep the tag matcher outside Terraform/HCL so backslashes cannot be doubled
# while Cloud Build configuration is rendered. The current commit is excluded:
# only an earlier, already published platform tag can be the diff baseline.
while IFS= read -r tag; do
  if [[ "${tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "${tag}"
    exit 0
  fi
done < <(git tag --merged "${commit}^" --sort=-version:refname)

