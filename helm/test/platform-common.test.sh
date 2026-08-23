#!/usr/bin/env bash
# Cross-profile contract tests: helper sync, schema strictness, forbidden
# policy-bypass surfaces, lint of every profile with its representative values.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/platform-lib.sh"

profiles=(platform-service platform-worker platform-job platform-stateful)

# Generated helper copies must match the canonical source.
if ! bash "${platform_dir}/sync-common.sh" check; then
  echo "FAIL: helm/platform/_common/_platform.tpl is out of sync; run bash helm/platform/sync-common.sh" >&2
  failures=$((failures + 1))
fi

# Every profile publishes a strict schema: valid JSON, additionalProperties
# false at the root, and none of the policy-bypass surfaces named by the Helm
# platform policy appear as accepted properties.
forbidden='podSpec|rawYaml|extraObjects|extraContainers|initContainers|sidecars|hostNetwork|hostPID|hostIPC|hostPort|privileged|nodeSelector|tolerations|affinity|annotations|serviceAccountName|imagePullSecrets|securityContext|podSecurityContext|volumes|volumeMounts|extraEnv|envFrom|extraVolumes|clusterRole|rbac|loadBalancerIP|externalIPs|type'
for profile in "${profiles[@]}"; do
  chart="${platform_dir}/${profile}"
  schema="${chart}/values.schema.json"
  [ -f "${schema}" ] || { echo "FAIL: ${profile} has no values.schema.json" >&2; failures=$((failures + 1)); continue; }
  if ! python3 - "${schema}" "${forbidden}" <<'PY'
import json, re, sys
schema_path, forbidden = sys.argv[1], sys.argv[2]
schema = json.load(open(schema_path))
assert schema.get("additionalProperties") is False, "root additionalProperties must be false"
pattern = re.compile(rf"^({forbidden})$")
errors = []
def walk(node, path, conditional=False):
    if isinstance(node, dict):
        if "properties" in node and isinstance(node["properties"], dict):
            # Conditional refinements (if/then/else/not) narrow an already strict
            # object and do not need to repeat additionalProperties.
            if not conditional and node.get("additionalProperties") is not False:
                errors.append(f"{path}: object with properties must set additionalProperties=false")
            for key, value in node["properties"].items():
                if pattern.match(key):
                    errors.append(f"{path}.{key}: forbidden policy-bypass property")
                walk(value, f"{path}.{key}", conditional)
        if "items" in node:
            walk(node["items"], f"{path}[items]", conditional)
        for key in ("then", "else", "if", "not"):
            if key in node:
                walk(node[key], f"{path}[{key}]", True)
        for key in ("oneOf", "anyOf", "allOf"):
            for index, sub in enumerate(node.get(key, [])):
                walk(sub, f"{path}[{key}][{index}]", True)
        for key, value in node.get("definitions", {}).items():
            walk(value, f"#/definitions/{key}", conditional)
walk(schema, "$")
if errors:
    print("\n".join(errors))
    sys.exit(1)
PY
  then
    echo "FAIL: ${profile} schema violates the typed extension boundary" >&2
    failures=$((failures + 1))
  fi

  # Chart metadata: SemVer, profile annotation, application type.
  version="$(awk '$1 == "version:" { print $2; exit }' "${chart}/Chart.yaml")"
  if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "FAIL: ${profile} Chart.yaml version ${version} is not plain SemVer" >&2
    failures=$((failures + 1))
  fi
  grep -Fq "platform.yourown.chat/profile: ${profile}" "${chart}/Chart.yaml" || { echo "FAIL: ${profile} Chart.yaml lacks the profile annotation" >&2; failures=$((failures + 1)); }
  grep -Fq "type: application" "${chart}/Chart.yaml" || { echo "FAIL: ${profile} must be an application chart" >&2; failures=$((failures + 1)); }

  # The public profile stays generic: no hardcoded product host, registry
  # project or namespace. Every namespace comes from the release.
  if grep -RhE 'yourown\.chat' "${chart}/templates" | grep -Ev 'platform\.yourown\.chat/' | grep -q .; then
    echo "FAIL: ${profile} templates contain a product host or name" >&2
    failures=$((failures + 1))
  fi
  if grep -RhE 'pkg\.dev/' "${chart}/templates" | grep -Ev '\\\.pkg\\\.dev/' | grep -q .; then
    echo "FAIL: ${profile} templates hardcode a registry project" >&2
    failures=$((failures + 1))
  fi
  if grep -RhE '^ *namespace:' "${chart}/templates" | grep -Ev 'Release\.Namespace' | grep -q .; then
    echo "FAIL: ${profile} templates hardcode a namespace" >&2
    failures=$((failures + 1))
  fi

  # The profile is not renderable without wrapper values (no hidden defaults
  # that could deploy an unnamed or untagged workload).
  if helm template probe "${chart}" >/dev/null 2>&1; then
    echo "FAIL: ${profile} renders without wrapper values" >&2
    failures=$((failures + 1))
  fi
done

# Lint every profile with its representative values.
helm lint "${platform_dir}/platform-service" -f "${fixture_dir}/service-valid.yaml" >/dev/null
helm lint "${platform_dir}/platform-worker" -f "${fixture_dir}/worker-valid.yaml" >/dev/null
helm lint "${platform_dir}/platform-job" -f "${fixture_dir}/job-valid.yaml" >/dev/null
helm lint "${platform_dir}/platform-job" -f "${fixture_dir}/job-cron-valid.yaml" >/dev/null
helm lint "${platform_dir}/platform-stateful" -f "${fixture_dir}/stateful-valid.yaml" >/dev/null

finish
