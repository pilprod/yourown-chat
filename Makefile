SHELL := /bin/bash

export CHART_NAME ?= yourown-chat
export CHART_DIR ?= helm/yourown-chat
export CHART_REPOSITORY ?= oci://southamerica-east1-docker.pkg.dev/gcloud-production-1/mattermost
export CHART_PACKAGE_DIR ?= /tmp/yourown-chat-chart
export KUBECONFIG ?= /etc/rancher/rke2/rke2.yaml

.PHONY: chart-version lint package-chart push-chart publish-chart ensure-local-path-storage repair-dev-storage deploy

chart-version:
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; printf '%s\n' "$${chart_version}"

lint:
	@helm lint "$(CHART_DIR)"

package-chart:
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; rm -rf "$(CHART_PACKAGE_DIR)"; mkdir -p "$(CHART_PACKAGE_DIR)"; helm lint "$(CHART_DIR)"; helm package "$(CHART_DIR)" --version "$${chart_version}" --app-version "$${chart_version}" --destination "$(CHART_PACKAGE_DIR)"

push-chart: package-chart
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; if [[ -z "$${chart_version}" ]]; then echo "CHART_VERSION or TAG_NAME is required" >&2; exit 1; fi; if [[ ! "$${chart_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]]; then echo "Chart version must be numeric X.Y.Z, got: $${chart_version}" >&2; exit 1; fi; registry_host="$${CHART_REPOSITORY#oci://}"; registry_host="$${registry_host%%/*}"; gcloud auth print-access-token | helm registry login -u oauth2accesstoken --password-stdin "https://$${registry_host}"; helm push "$(CHART_PACKAGE_DIR)/$(CHART_NAME)-$${chart_version}.tgz" "$${CHART_REPOSITORY}"

publish-chart: push-chart

ensure-local-path-storage:
	@if ! kubectl get storageclass/local-path >/dev/null 2>&1 || ! kubectl -n local-path-storage get deployment/local-path-provisioner >/dev/null 2>&1; then kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml; fi
	@kubectl wait -n local-path-storage deployment/local-path-provisioner --for=condition=Available --timeout=180s
	@kubectl annotate storageclass/local-path storageclass.kubernetes.io/is-default-class=true --overwrite

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
	@$(MAKE) ensure-local-path-storage
	@helm repo add external-secrets https://charts.external-secrets.io --force-update
	@helm repo add jetstack https://charts.jetstack.io --force-update
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
	@helm repo add mattermost https://helm.mattermost.com --force-update
	@helm repo update
	@helm upgrade -i external-secrets -n external-secrets --create-namespace --set installCRDs=true external-secrets/external-secrets --wait
	@kubectl wait crd/clustersecretstores.external-secrets.io --for=condition=Established --timeout=180s
	@kubectl wait crd/externalsecrets.external-secrets.io --for=condition=Established --timeout=180s
	@helm upgrade -i cert-manager -n cert-manager --create-namespace --set crds.enabled=true jetstack/cert-manager --wait
	@helm upgrade -i ingress-nginx -n ingress-nginx --create-namespace --set controller.kind=DaemonSet --set controller.hostNetwork=true --set controller.dnsPolicy=ClusterFirstWithHostNet --set controller.service.enabled=false --set controller.ingressClassResource.default=true --set controller.allowSnippetAnnotations=false --set controller.config.annotations-risk-level=Medium --set controller.config.server-tokens=false ingress-nginx/ingress-nginx --wait
	@kubectl apply -f ingress-nginx-autoupdate.yaml
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
	@set -euo pipefail; chart_version="$${CHART_VERSION:-$${TAG_NAME:-}}"; helm upgrade -i yourown-chat -n mattermost --create-namespace "$${CHART_REPOSITORY}/$(CHART_NAME)" --version "$${chart_version}" --wait
	@kubectl -n mattermost wait externalsecret/s3-credentials --for=condition=Ready --timeout=180s
	@kubectl -n mattermost wait externalsecret/postgres-connection --for=condition=Ready --timeout=180s
	@kubectl -n mattermost rollout status statefulset/mattermost-dev-postgres --timeout=180s
	@if ! kubectl -n mattermost wait externalsecret/matterbridge --for=condition=Ready --timeout=30s; then echo "matterbridge ExternalSecret is not ready yet; create the matterbridge-* GCP secrets to start the bridge."; fi
	@kubectl -n mattermost get mattermost,pods,svc,endpoints || true
