#!/usr/bin/env bash
# Runs every platform profile test. UPDATE_GOLDEN=1 regenerates snapshots.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for test in platform-common platform-service platform-worker platform-job platform-stateful platform-release; do
  echo "==> ${test}"
  bash "${here}/${test}.test.sh" || status=1
done
exit "${status}"
