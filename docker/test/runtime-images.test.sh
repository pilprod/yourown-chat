#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

node_runtime="${repo_root}/docker/base/node.Dockerfile"
python_runtime="${repo_root}/docker/base/python.Dockerfile"
base_runtime="${repo_root}/docker/base/Dockerfile"
cloudflared_runtime="${repo_root}/docker/mcp/cloudflared/Dockerfile"
catalog="${repo_root}/docker/images.tsv"
upstreams="${repo_root}/docker/mcp/upstreams.env"

grep -Fq \
  'alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b' \
  "${base_runtime}"
if grep -Eq 'debian:|apt-get|perl' "${base_runtime}"; then
  printf 'Shared runtime base must not publish Debian or Perl packages\n' >&2
  exit 1
fi

grep -Fq \
  'node:22.23.1-alpine3.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2' \
  "${node_runtime}"
grep -Fq \
  'COPY --from=language-runtime /usr/local/bin/node /usr/local/bin/node' \
  "${node_runtime}"
if grep -Fq 'COPY --from=language-runtime /usr/local/ /usr/local/' \
  "${node_runtime}"; then
  printf 'Node runtime must not copy npm/Corepack into the final image\n' >&2
  exit 1
fi

grep -Fq 'COPY --from=uv-runtime /uv /uvx /usr/local/bin/' \
  "${python_runtime}"
if grep -Eq 'pip install|python3-venv' "${python_runtime}"; then
  printf 'Python runtime must not install pip, virtualenv, or setuptools\n' >&2
  exit 1
fi

grep -Fq \
  'golang:1.26.6-bookworm@sha256:116d58cbd88c1297624acc6e967a060012422bacf9930927e23fb719189c6f36' \
  "${cloudflared_runtime}"
grep -Fq 'make VERSION="${UPSTREAM_VERSION}" cloudflared' \
  "${cloudflared_runtime}"
grep -Fq \
  'build_args+=(--build-arg "UPSTREAM_VERSION=${image_build_version}")' \
  "${repo_root}/docker/build-images.sh"
grep -Fq \
  'CLOUDFLARED_REVISION=3a2b45c2a511fcdd81b68c190938e4ffadbea5dc' \
  "${upstreams}"

while IFS= read -r row; do
  [[ -z "${row}" || "${row}" == \#* ]] && continue
  field_count="$(awk -F '\t' '{print NF}' <<< "${row}")"
  if [[ "${field_count}" != 16 ]]; then
    printf 'Image catalog row has %s fields, expected 16: %s\n' \
      "${field_count}" "${row}" >&2
    exit 1
  fi
done < "${catalog}"

node_apps=(
  google-cloud
  terraform-stacks
)
for app in "${node_apps[@]}"; do
  dockerfile="${repo_root}/docker/mcp/${app}/Dockerfile"
  grep -Fq 'FROM ${BUILD_IMAGE} AS dependencies' "${dockerfile}"
  grep -Fq \
    'COPY --from=dependencies --chown=65532:65532 /app/node_modules ./node_modules' \
    "${dockerfile}"
done

printf 'Runtime image policy tests passed\n'
