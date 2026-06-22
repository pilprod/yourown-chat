SHELL := /bin/bash

export CHART_NAME ?= yourown-chat
export CHART_DIR ?= helm/yourown-chat
export CHART_REPOSITORY ?= oci://southamerica-east1-docker.pkg.dev/gcloud-production-1/mattermost
export CHART_PACKAGE_DIR ?= /tmp/yourown-chat-chart
export KUBECONFIG ?= /etc/rancher/rke2/rke2.yaml

.PHONY: chart-version lint package-chart push-chart publish-chart repair-dev-storage deploy

chart-version:
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; printf '%s\n' "$${chart_version}"

lint:
	@helm lint "$(CHART_DIR)"

package-chart:
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; rm -rf "$(CHART_PACKAGE_DIR)"; mkdir -p "$(CHART_PACKAGE_DIR)"; helm lint "$(CHART_DIR)"; helm package "$(CHART_DIR)" --version "$${chart_version}" --app-version "$${chart_version}" --destination "$(CHART_PACKAGE_DIR)"

push-chart: package-chart
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; registry_host="$${CHART_REPOSITORY#oci://}"; registry_host="$${registry_host%%/*}"; gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://$${registry_host}"; helm push "$(CHART_PACKAGE_DIR)/$(CHART_NAME)-$${chart_version}.tgz" "$${CHART_REPOSITORY}"

publish-chart: push-chart

repair-dev-storage:
	@set -euo pipefail; for pvc in yourown-chat-dev data-mattermost-dev-postgres-0; do \
		if kubectl -n mattermost get pvc "$${pvc}" >/dev/null 2>&1; then \
			phase="$$(kubectl -n mattermost get pvc "$${pvc}" -o jsonpath='{.status.phase}')"; \
			storage_class="$$(kubectl -n mattermost get pvc "$${pvc}" -o jsonpath='{.spec.storageClassName}')"; \
			if [[ "$${phase}" == "Pending" && -z "$${storage_class}" ]]; then \
				echo "Deleting broken dev PVC $${pvc}: Pending with no storageClassName"; \
				kubectl -n mattermost delete pvc "$${pvc}" --wait=false; \
				kubectl -n mattermost wait --for=delete "pvc/$${pvc}" --timeout=120s >/dev/null 2>&1 || true; \
			fi; \
		fi; \
	done

deploy:
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; echo "Deploying chart $${CHART_REPOSITORY}/$(CHART_NAME):$${chart_version}"
	@kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -
	@helm repo add mattermost https://helm.mattermost.com --force-update
	@helm repo update
	@helm upgrade -i mattermost -n mattermost --create-namespace -f operator.yaml mattermost/mattermost-operator --wait
	@if [[ -f clusterissuer.yaml ]]; then kubectl apply -f clusterissuer.yaml; fi
	@if [[ -f certs.yaml ]]; then kubectl apply -n mattermost -f certs.yaml; fi
	@set -euo pipefail; for item in \
		"clustersecretstore|gcp-secret-manager|" \
		"externalsecret|s3-credentials|mattermost" \
		"externalsecret|postgres-connection|mattermost" \
		"externalsecret|matterbridge|mattermost" \
		"secret|postgres-connection-dev|mattermost" \
		"statefulset|mattermost-dev-postgres|mattermost" \
		"service|mattermost-dev-postgres|mattermost" \
		"configmap|matterbridge-config|mattermost" \
		"deployment|matterbridge|mattermost" \
		"mattermost|yourown-chat|mattermost" \
		"mattermost|yourown-chat-dev|mattermost" \
		"ingress|mattermost|mattermost" \
		"ingress|mattermost-dev|mattermost"; do \
		IFS='|' read -r kind name namespace <<<"$${item}"; namespace_args=(); if [[ -n "$${namespace}" ]]; then namespace_args=(-n "$${namespace}"); fi; if kubectl "$${namespace_args[@]}" get "$${kind}/$${name}" >/dev/null 2>&1; then kubectl "$${namespace_args[@]}" label "$${kind}/$${name}" app.kubernetes.io/managed-by=Helm --overwrite; kubectl "$${namespace_args[@]}" annotate "$${kind}/$${name}" meta.helm.sh/release-name=yourown-chat meta.helm.sh/release-namespace=mattermost --overwrite; fi; \
	done
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; image_args=(); if [[ -n "$${IMAGE_TAG:-}" ]]; then image_args+=(--set-string "instances.prod.imageTag=$${IMAGE_TAG}"); fi; if [[ -n "$${DEV_IMAGE_TAG:-}" ]]; then image_args+=(--set-string "instances.dev.imageTag=$${DEV_IMAGE_TAG}"); fi; if [[ -n "$${PROD_IMAGE_DIGEST:-}" ]]; then image_args+=(--set-string "instances.prod.imageDigest=$${PROD_IMAGE_DIGEST}"); fi; if [[ -n "$${DEV_IMAGE_DIGEST:-}" ]]; then image_args+=(--set-string "instances.dev.imageDigest=$${DEV_IMAGE_DIGEST}"); fi; helm upgrade -i yourown-chat -n mattermost --create-namespace "$${CHART_REPOSITORY}/$(CHART_NAME)" --version "$${chart_version}" "$${image_args[@]}" --wait
	@kubectl -n mattermost wait externalsecret/s3-credentials --for=condition=Ready --timeout=180s
	@kubectl -n mattermost wait externalsecret/postgres-connection --for=condition=Ready --timeout=180s
	@kubectl -n mattermost rollout status statefulset/mattermost-dev-postgres --timeout=180s
	@set -euo pipefail; for mattermost_name in yourown-chat yourown-chat-dev; do \
		echo "Waiting for Mattermost $${mattermost_name} to become ready"; \
		for attempt in {1..60}; do \
			state="$$(kubectl -n mattermost get mattermost "$${mattermost_name}" -o jsonpath='{.status.state}' 2>/dev/null || true)"; \
			error="$$(kubectl -n mattermost get mattermost "$${mattermost_name}" -o jsonpath='{.status.error}' 2>/dev/null || true)"; \
			if [[ "$${state}" == "ready" || "$${state}" == "stable" ]]; then echo "Mattermost $${mattermost_name} is $${state}"; break; fi; \
			if [[ -n "$${error}" ]]; then echo "Mattermost $${mattermost_name} error: $${error}" >&2; fi; \
			if [[ "$${attempt}" -eq 60 ]]; then echo "Timed out waiting for Mattermost $${mattermost_name}; current state: $${state:-unknown}" >&2; kubectl -n mattermost get mattermost "$${mattermost_name}" -o wide || true; kubectl -n mattermost describe mattermost "$${mattermost_name}" || true; exit 1; fi; \
			echo "Waiting for Mattermost $${mattermost_name} ($${attempt}/60), current state: $${state:-unknown}"; \
			sleep 5; \
		done; \
	done
	@if kubectl -n mattermost get externalsecret/matterbridge >/dev/null 2>&1; then if ! kubectl -n mattermost wait externalsecret/matterbridge --for=condition=Ready --timeout=30s; then echo "matterbridge ExternalSecret is not ready yet; create the matterbridge-* GCP secrets to start the bridge."; fi; else echo "matterbridge is disabled; skipping matterbridge ExternalSecret wait."; fi
	@kubectl -n mattermost get mattermost,pods,svc,endpoints || true
