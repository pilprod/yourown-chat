#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

node_runtime="${repo_root}/docker/base/node.Dockerfile"
python_runtime="${repo_root}/docker/base/python.Dockerfile"
cloudflared_runtime="${repo_root}/docker/mcp/cloudflared/Dockerfile"
catalog="${repo_root}/docker/images.tsv"
upstreams="${repo_root}/docker/mcp/upstreams.env"

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
  'golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651' \
  "${cloudflared_runtime}"
grep -Fq 'make VERSION="${UPSTREAM_VERSION}" cloudflared' \
  "${cloudflared_runtime}"
grep -Fq \
  'build_args+=(--build-arg "UPSTREAM_VERSION=${image_build_version}")' \
  "${repo_root}/docker/build-images.sh"
grep -Fq \
  'TERRAFORM_MCP_SOURCE=hashicorp/terraform-mcp-server@sha256:312d63756b5474df384b1844af55b58ca48cbe0996871e1d6c4239bfcd6fcd29' \
  "${upstreams}"
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
  whatsapp-business
  whatsapp-personal
)
for app in "${node_apps[@]}"; do
  dockerfile="${repo_root}/docker/mcp/${app}/Dockerfile"
  grep -Fq 'FROM ${BUILD_IMAGE} AS dependencies' "${dockerfile}"
  grep -Fq \
    'COPY --from=dependencies --chown=65532:65532 /app/node_modules ./node_modules' \
    "${dockerfile}"
done

printf 'Runtime image policy tests passed\n'
