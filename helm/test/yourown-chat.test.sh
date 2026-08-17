#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="$(mktemp)"
identity_only="$(mktemp)"
trap 'rm -f "${rendered}" "${identity_only}"' EXIT

helm template yourown-chat "${repo_root}/helm/yourown-chat" \
  --namespace yourown-chat-server \
  --set yourown_chat_control_api_enabled=true \
  --set yourown_chat_registration_enabled=true \
  --set yourown_chat_control_api_image=example.invalid/control-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set yourown_chat_auth_api_image=example.invalid/auth-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  --set yourown_chat_identity_api_image=example.invalid/identity-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --set yourown_chat_identity_admin_image=example.invalid/identity-admin@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  --set yourown_chat_identity_migrate_image=example.invalid/identity-migrate@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --set backend_control_api_gsa=control@example.invalid \
  --set auth_api_gsa=auth@example.invalid \
  --set identity_api_gsa=identity@example.invalid \
  --set identity_admin_gsa=identity-admin@example.invalid \
  --set identity_migrate_gsa=migrate@example.invalid \
  --set server_secret_project=test-project \
  --set cluster_dns_ip=10.30.0.10 \
  --set cloudsql_private_ip=10.20.30.40 > "${rendered}"

grep -Fq 'name: yourown-chat-identity-api' "${rendered}"
grep -Fq 'name: yourown-chat-auth-api' "${rendered}"
grep -Fq 'name: yourown-chat-identity-admin' "${rendered}"
grep -Fq 'name: yourown-chat-control-api' "${rendered}"
grep -Fq 'name: yourown-chat-identity-migrate-' "${rendered}"
grep -Fq 'IDENTITY_DATABASE_URL_FILE' "${rendered}"
grep -Fq 'IDENTITY_ADMIN_TOKEN_FILE' "${rendered}"
grep -Fq 'IDENTITY_REGISTRATION_ENABLED' "${rendered}"
grep -Fq 'value: "true"' "${rendered}"
grep -Fq 'secrets/yourown-chat-identity-database-url/versions/latest' "${rendered}"
grep -Fq 'cidr: "10.20.30.40/32"' "${rendered}"
grep -Fq 'cidr: "10.30.0.10/32"' "${rendered}"
grep -Fq 'path: ^/(\.well-known/oauth-authorization-server|authorize|callback|token)?/?$' "${rendered}"
! grep -Fq 'v1/auth/oidc/sessions' "${rendered}"
grep -Fq 'host: auth.yourown.chat' "${rendered}"
grep -Fq 'path: /(realms|resources)(/.*)?' "${rendered}"
grep -Fq 'path: /admin/(realms|serverinfo)(/.*)?' "${rendered}"
! grep -Fq 'path: /auth/' "${rendered}"
! grep -Fq 'v1/auth/registrations' "${rendered}"
grep -Fq 'nginx.ingress.kubernetes.io/limit-rps: "1"' "${rendered}"
! grep -Fq 'path: /internal' "${rendered}"
! grep -Eq 'type: (LoadBalancer|NodePort)' "${rendered}"
! grep -Fq '169.254.169.254' "${rendered}"
[[ "$(grep -Fc 'automountServiceAccountToken: false' "${rendered}")" -ge 8 ]]

identity_api_document="$(awk 'BEGIN { RS="---" } /kind: Deployment/ && /name: yourown-chat-identity-api/ { print }' "${rendered}")"
! grep -Fq 'IDENTITY_ADMIN_TOKEN_FILE' <<<"${identity_api_document}"
! grep -Fq 'IDENTITY_BOOTSTRAP_WORKSPACE_ID' <<<"${identity_api_document}"
admin_document="$(awk 'BEGIN { RS="---" } /kind: Deployment/ && /name: yourown-chat-identity-admin/ { print }' "${rendered}")"
grep -Fq 'IDENTITY_ADMIN_TOKEN_FILE' <<<"${admin_document}"
grep -Fq 'IDENTITY_BOOTSTRAP_WORKSPACE_ID' <<<"${admin_document}"

helm template yourown-chat "${repo_root}/helm/yourown-chat" \
  --namespace yourown-chat-server \
  --set yourown_chat_auth_api_image=example.invalid/auth-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  --set yourown_chat_identity_api_image=example.invalid/identity-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --set yourown_chat_identity_admin_image=example.invalid/identity-admin@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  --set yourown_chat_identity_migrate_image=example.invalid/identity-migrate@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  --set backend_control_api_gsa=control@example.invalid \
  --set auth_api_gsa=auth@example.invalid \
  --set identity_api_gsa=identity@example.invalid \
  --set identity_admin_gsa=identity-admin@example.invalid \
  --set identity_migrate_gsa=migrate@example.invalid \
  --set server_secret_project=test-project \
  --set cluster_dns_ip=10.30.0.10 \
  --set cloudsql_private_ip=10.20.30.40 > "${identity_only}"
grep -Fq 'name: yourown-chat-identity-api' "${identity_only}"
grep -Fq 'name: yourown-chat-auth-api' "${identity_only}"
grep -Fq 'name: yourown-chat-identity-admin' "${identity_only}"
! grep -Fq 'name: yourown-chat-control-api' "${identity_only}"

grep -Fq 'chartPath: yourown-chat' "${repo_root}/helm/skaffold-yourown-chat.yaml"
grep -Fq 'namespace: yourown-chat-server' "${repo_root}/helm/skaffold-yourown-chat.yaml"
grep -Fq 'services      = "control-api auth-api identity-api identity-admin identity-migrate"' "${repo_root}/terraform/app-gcp/modules/deploy-release/backend-image.tf"
grep -Fq -- '--build-arg SERVICE=$$service' "${repo_root}/terraform/app-gcp/modules/deploy-release/backend-image.tf"

printf 'YourOwn.Chat server render tests passed\n'
