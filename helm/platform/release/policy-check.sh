#!/usr/bin/env bash
# Platform policy check for a rendered manifest produced from platform profile
# charts. Used by the release assembler before a Cloud Deploy release is
# created and by helm/test/platform-lib.sh. Exit 1 with one line per
# violation; exit 0 when the manifest satisfies the platform invariants.
set -euo pipefail

file="${1:?usage: policy-check.sh <rendered-manifest.yaml>}"
violations=0

fail() {
  echo "policy: $1" >&2
  violations=$((violations + 1))
}

must_not_regex() { grep -Eq -- "$1" "${file}" && fail "$2" || true; }
must_regex()     { grep -Eq -- "$1" "${file}" || fail "$2"; }

must_not_regex 'type: (NodePort|ExternalName)' "node-level or external-name Service is not permitted"
must_not_regex '^ *hostNetwork:' "host networking is not permitted"
must_not_regex '^ *hostPID:' "host PID namespace is not permitted"
must_not_regex '^ *hostIPC:' "host IPC namespace is not permitted"
must_not_regex '^ *hostPort:' "host ports are not permitted"
must_not_regex 'privileged: true' "privileged containers are not permitted"
must_not_regex '^kind: Secret$' "native Secret objects are not rendered by a service release"
must_not_regex '^kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding)$' "RBAC objects are not rendered by a service release"
must_not_regex '^ *secretKeyRef:' "plaintext secret environment variables are not permitted"
must_not_regex '^ *image: "?[^@" ]*"?$' "every image must be a digest-qualified reference"
must_not_regex '^ *image: "?(docker\.io|gcr\.io|ghcr\.io|quay\.io|registry\.k8s\.io)/' "images must come from the platform Artifact Registry"
must_not_regex '^ *imagePullSecrets:' "image pull secrets are not permitted"
must_not_regex 'allowPrivilegeEscalation: true' "privilege escalation is not permitted"
must_not_regex 'readOnlyRootFilesystem: false' "the root filesystem must be read-only"
must_not_regex 'runAsNonRoot: false' "containers must run as non-root"
must_not_regex 'automountServiceAccountToken: true' "service account tokens are not auto-mounted"

must_regex 'policyTypes: \[Ingress, Egress\]' "a deny-by-default NetworkPolicy is required"
must_regex 'platform.yourown.chat/profile:' "rendered workloads must carry the platform profile label"

# Every workload controller must come from a platform profile.
controllers="$(grep -Ec '^kind: (Deployment|StatefulSet|Job|CronJob|DaemonSet|ReplicaSet|Pod)$' "${file}" || true)"
profile_controllers="$(awk 'BEGIN { RS="---" } /\nkind: (Deployment|StatefulSet|Job|CronJob|DaemonSet|ReplicaSet|Pod)\n/ && /platform.yourown.chat\/profile: platform-(service|worker|job|stateful)/ { n++ } END { print n+0 }' "${file}")"
if [ "${controllers}" -ne "${profile_controllers}" ]; then
  fail "${controllers} workload controller(s) rendered but only ${profile_controllers} carry a platform profile label"
fi
if grep -Eq '^kind: (DaemonSet|ReplicaSet|Pod)$' "${file}"; then
  fail "DaemonSet, bare ReplicaSet and bare Pod are not approved workload profiles"
fi

if [ "${violations}" -ne 0 ]; then
  echo "policy: ${violations} violation(s) in ${file}" >&2
  exit 1
fi
