#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="$(mktemp)"
identity_only="$(mktemp)"
trap 'rm -f "${rendered}" "${identity_only}"' EXIT

helm template yourown-chat "${repo_root}/helm/yourown-chat" \
  --namespace server-edge \
  --set yourown_chat_control_api_enabled=true \
  --set yourown_chat_registration_enabled=true \
  --set yourown_chat_control_api_image=example.invalid/control-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set yourown_chat_auth_api_image=example.invalid/auth-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  --set yourown_chat_transport_api_image=example.invalid/transport-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  --set yourown_chat_identity_api_image=example.invalid/identity-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --set yourown_chat_identity_admin_image=example.invalid/identity-admin@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  --set yourown_chat_identity_migrate_image=example.invalid/identity-migrate@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --set backend_control_api_gsa=control@example.invalid \
  --set auth_api_gsa=auth@example.invalid \
  --set transport_api_gsa=transport@example.invalid \
  --set identity_api_gsa=identity@example.invalid \
  --set identity_admin_gsa=identity-admin@example.invalid \
  --set identity_migrate_gsa=migrate@example.invalid \
  --set server_secret_project=test-project \
  --set apple_association_app_id=TEAMID.com.example.app \
  --set cluster_dns_ip=10.30.0.10 \
  --set cloudsql_private_ip=10.20.30.40 > "${rendered}"

grep -Fq 'name: api' "${rendered}"
grep -Fq 'name: auth' "${rendered}"
grep -Fq 'name: transport' "${rendered}"
grep -Fq 'name: admin' "${rendered}"
grep -Fq 'name: control' "${rendered}"
grep -Fq 'name: migrate-' "${rendered}"
grep -Fq 'namespace: server-edge' "${rendered}"
grep -Fq 'namespace: server-identity' "${rendered}"
grep -Fq 'namespace: server-control' "${rendered}"
grep -Fq 'http://auth.server-edge.svc.cluster.local:8083' "${rendered}"
grep -Fq 'http://api.server-identity.svc.cluster.local:8081' "${rendered}"
grep -Fq 'http://control.server-control.svc.cluster.local:8080' "${rendered}"
! grep -Eq 'name: yourown-chat-(transport|auth|identity|control)' "${rendered}"
grep -Fq 'IDENTITY_DATABASE_URL_FILE' "${rendered}"
grep -Fq 'IDENTITY_ADMIN_TOKEN_FILE' "${rendered}"
grep -Fq 'IDENTITY_REGISTRATION_ENABLED' "${rendered}"
grep -Fq 'value: "true"' "${rendered}"
grep -Fq 'secrets/yourown-chat-identity-database-url/versions/latest' "${rendered}"
grep -Fq 'cidr: "10.20.30.40/32"' "${rendered}"
grep -Fq 'cidr: "10.30.0.10/32"' "${rendered}"
! grep -Fq 'authorize|callback|token' "${rendered}"
grep -Fq 'path: /transport/v1' "${rendered}"
grep -Fq 'path: /transport/v1/socket' "${rendered}"
grep -Fq 'pathType: Exact' "${rendered}"
! grep -Fq 'name: api' < <(awk 'BEGIN { RS="---" } /kind: Ingress/ { print }' "${rendered}")
! grep -Fq 'v1/auth/oidc/sessions' "${rendered}"
! grep -Fq 'host: auth.yourown.chat' "${rendered}"
grep -Fq 'path: /.well-known/apple-app-site-association' "${rendered}"
grep -Fq 'AUTH_PASSKEY_RP_ID' "${rendered}"
grep -Fq 'AUTH_PASSKEY_RECORD_KEY_FILE' "${rendered}"
grep -Fq 'AUTH_APPLE_ASSOCIATION_APP_ID' "${rendered}"
grep -Fq 'TEAMID.com.example.app' "${rendered}"
grep -Fq 'secrets/yourown-chat-passkey-record-key/versions/latest' "${rendered}"
! grep -Fq '/realms/' "${rendered}"
! grep -Fq '/admin/' "${rendered}"
! grep -Fq 'path: /auth/' "${rendered}"
! grep -Fq 'v1/auth/registrations' "${rendered}"
grep -Fq 'nginx.ingress.kubernetes.io/enable-access-log: "false"' "${rendered}"
! grep -Fq 'AUTH_PUBLIC_ORIGIN' "${rendered}"
! grep -Fq 'AUTH_APPLE_APP_ID' "${rendered}"
grep -Fq 'TRANSPORT_PRIVATE_KEY_FILE' "${rendered}"
grep -Fq 'IDENTITY_BOOTSTRAP_WORKSPACE_MATTERMOST_TRANSPORT_AVAILABLE' "${rendered}"
grep -Fq 'value: quantum' "${rendered}"
grep -Fq 'secrets/yourown-chat-transport-private-key/versions/latest' "${rendered}"
grep -Fq 'IDENTITY_BOOTSTRAP_PASSWORD_FILE' "${rendered}"
grep -Fq 'yourown-chat-pilprod-initial-password' "${rendered}"
! grep -Fqi 'keycloak' "${rendered}"
! grep -Fq 'path: /internal' "${rendered}"
! grep -Eq 'type: (LoadBalancer|NodePort)' "${rendered}"
! grep -Fq '169.254.169.254' "${rendered}"
[[ "$(grep -Fc 'automountServiceAccountToken: false' "${rendered}")" -ge 8 ]]

identity_api_document="$(awk 'BEGIN { RS="---" } /kind: Deployment/ && /name: api/ { print }' "${rendered}")"
! grep -Fq 'IDENTITY_ADMIN_TOKEN_FILE' <<<"${identity_api_document}"
! grep -Fq 'IDENTITY_BOOTSTRAP_WORKSPACE_ID' <<<"${identity_api_document}"
admin_document="$(awk 'BEGIN { RS="---" } /kind: Deployment/ && /name: admin/ { print }' "${rendered}")"
grep -Fq 'IDENTITY_ADMIN_TOKEN_FILE' <<<"${admin_document}"
grep -Fq 'IDENTITY_BOOTSTRAP_WORKSPACE_ID' <<<"${admin_document}"

helm template yourown-chat "${repo_root}/helm/yourown-chat" \
  --namespace server-edge \
  --set yourown_chat_auth_api_image=example.invalid/auth-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  --set yourown_chat_transport_api_image=example.invalid/transport-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  --set yourown_chat_identity_api_image=example.invalid/identity-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --set yourown_chat_identity_admin_image=example.invalid/identity-admin@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  --set yourown_chat_identity_migrate_image=example.invalid/identity-migrate@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --set backend_control_api_gsa=control@example.invalid \
  --set auth_api_gsa=auth@example.invalid \
  --set transport_api_gsa=transport@example.invalid \
  --set identity_api_gsa=identity@example.invalid \
  --set identity_admin_gsa=identity-admin@example.invalid \
  --set identity_migrate_gsa=migrate@example.invalid \
  --set server_secret_project=test-project \
  --set apple_association_app_id=TEAMID.com.example.app \
  --set cluster_dns_ip=10.30.0.10 \
  --set cloudsql_private_ip=10.20.30.40 > "${identity_only}"
grep -Fq 'name: api' "${identity_only}"
grep -Fq 'name: auth' "${identity_only}"
grep -Fq 'name: transport' "${identity_only}"
grep -Fq 'name: admin' "${identity_only}"
! grep -Fq 'name: control' "${identity_only}"

grep -Fq 'chartPath: yourown-chat' "${repo_root}/helm/skaffold-yourown-chat.yaml"
grep -Fq 'namespace: server-edge' "${repo_root}/helm/skaffold-yourown-chat.yaml"
grep -Fq 'services      = "control-api auth-api transport-api identity-api identity-admin identity-migrate"' "${repo_root}/terraform/app-gcp/modules/deploy-release/backend-image.tf"
grep -Fq -- '--build-arg SERVICE=$$service' "${repo_root}/terraform/app-gcp/modules/deploy-release/backend-image.tf"

printf 'YourOwn.Chat server render tests passed\n'
