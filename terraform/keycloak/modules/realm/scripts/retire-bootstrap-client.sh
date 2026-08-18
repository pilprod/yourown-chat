#!/bin/sh
set -eu
set +x

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM

curl -fsS -o "$work_dir/token.json" \
  -X POST 'https://auth.yourown.chat/realms/master/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'client_id=bootstrap-admin' \
  --data-urlencode "client_secret=${KEYCLOAK_BOOTSTRAP_CLIENT_SECRET}"

access_token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' < "$work_dir/token.json")"
curl -fsS -o "$work_dir/clients.json" \
  -H "Authorization: Bearer ${access_token}" \
  'https://auth.yourown.chat/admin/realms/master/clients?clientId=bootstrap-admin'

client_id="$(python3 -c 'import json,sys; rows=json.load(sys.stdin); print(rows[0]["id"] if rows else "")' < "$work_dir/clients.json")"
if [ -n "$client_id" ]; then
  curl -fsS -o /dev/null -X DELETE \
    -H "Authorization: Bearer ${access_token}" \
    "https://auth.yourown.chat/admin/realms/master/clients/${client_id}"
fi
