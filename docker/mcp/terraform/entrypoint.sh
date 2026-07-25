#!/bin/sh
set -eu

if [ -n "${TFE_TOKEN_FILE:-}" ]; then
  TFE_TOKEN="$(cat "${TFE_TOKEN_FILE}")"
  export TFE_TOKEN
fi

exec /bin/terraform-mcp-server "$@"
