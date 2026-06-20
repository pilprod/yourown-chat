#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
export PATH="/var/lib/rancher/rke2/bin:${PATH}"

required_vars=(
  PROJECT_ID
  IMAGE_REPO
  IMAGE_TAG
  BUCKET_NAME
  SITE_URL
)

MATTERMOST_NAME="${MATTERMOST_NAME:-yourown-chat}"
INGRESS_NAME="${INGRESS_NAME:-mattermost}"
INGRESS_HOST="${INGRESS_HOST:-${SITE_URL#https://}}"
TLS_SECRET="${TLS_SECRET:-yourown-chat-tls}"
DB_SECRET_ID="${DB_SECRET_ID:-mattermost-db-datasource}"
DB_EXTERNAL_SECRET="${DB_EXTERNAL_SECRET:-postgres-connection}"
S3_EXTERNAL_SECRET="${S3_EXTERNAL_SECRET:-s3-credentials}"
DEPLOY_MATTERBRIDGE="${DEPLOY_MATTERBRIDGE:-true}"
DEPLOY_DEV_POSTGRES="${DEPLOY_DEV_POSTGRES:-false}"

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
done

wait_api_resource() {
  local resource_name="$1"
  local attempts="${2:-30}"

  for attempt in $(seq 1 "${attempts}"); do
    if kubectl api-resources --api-group=external-secrets.io -o name | grep -Eq "^${resource_name}(\.external-secrets\.io)?$"; then
      return 0
    fi

    if [[ "${attempt}" == "${attempts}" ]]; then
      echo "Kubernetes API resource is not available: ${resource_name}.external-secrets.io" >&2
      return 1
    fi

    sleep 2
  done
}

echo "Deploying Mattermost image ${IMAGE_REPO}:${IMAGE_TAG}"

image_ref="${IMAGE_REPO}:${IMAGE_TAG}"
image_wait_attempts="${IMAGE_WAIT_ATTEMPTS:-60}"
image_wait_seconds="${IMAGE_WAIT_SECONDS:-30}"

for attempt in $(seq 1 "${image_wait_attempts}"); do
  if gcloud artifacts docker images describe "${image_ref}" >/dev/null 2>&1; then
    break
  fi

  if [[ "${attempt}" == "${image_wait_attempts}" ]]; then
    echo "Mattermost image not found after ${image_wait_attempts} attempts: ${image_ref}" >&2
    exit 1
  fi

  echo "Mattermost image is not available yet (${attempt}/${image_wait_attempts}): ${image_ref}"
  sleep "${image_wait_seconds}"
done

kubectl create namespace mattermost --dry-run=client -o yaml | kubectl apply -f -
# kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm repo add external-secrets https://charts.external-secrets.io --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
# helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add mattermost https://helm.mattermost.com --force-update
helm repo update

helm upgrade -i external-secrets \
  -n external-secrets \
  --create-namespace \
  --set installCRDs=true \
  external-secrets/external-secrets \
  --wait

kubectl wait crd/clustersecretstores.external-secrets.io --for=condition=Established --timeout=180s
kubectl wait crd/externalsecrets.external-secrets.io --for=condition=Established --timeout=180s
wait_api_resource clustersecretstores
wait_api_resource externalsecrets

helm upgrade -i cert-manager \
  -n cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  jetstack/cert-manager \
  --wait

helm upgrade -i ingress-nginx \
  -n ingress-nginx \
  --create-namespace \
  --set controller.kind=DaemonSet \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.service.enabled=false \
  --set controller.ingressClassResource.default=true \
  --set controller.allowSnippetAnnotations=false \
  --set controller.config.annotations-risk-level=Medium \
  --set controller.config.server-tokens=false \
  ingress-nginx/ingress-nginx \
  --wait

kubectl apply -f ingress-nginx-autoupdate.yaml

# helm upgrade -i monitoring \
#   -n monitoring \
#   --create-namespace \
#   --set alertmanager.enabled=false \
#   --set prometheus-pushgateway.enabled=false \
#   --set server.persistentVolume.enabled=false \
#   --set server.retention=2d \
#   --set server.resources.requests.cpu=50m \
#   --set server.resources.requests.memory=192Mi \
#   prometheus-community/prometheus \
#   --wait

sed \
  -e "s|__PROJECT_ID__|${PROJECT_ID}|g" \
  -e "s|__S3_EXTERNAL_SECRET__|${S3_EXTERNAL_SECRET}|g" \
  gcp/externalsecrets.yaml >/tmp/externalsecrets.yaml

kubectl apply -f /tmp/externalsecrets.yaml
kubectl -n mattermost wait "externalsecret/${S3_EXTERNAL_SECRET}" --for=condition=Ready --timeout=180s

if [[ "${DEPLOY_DEV_POSTGRES}" == "true" ]]; then
  if ! kubectl -n mattermost get secret "${DB_EXTERNAL_SECRET}" >/dev/null 2>&1; then
    dev_postgres_password="$(python3 -c 'import secrets,string; alphabet=string.ascii_letters+string.digits; print("".join(secrets.choice(alphabet) for _ in range(32)))')"
    dev_postgres_dsn="postgres://mmuser:${dev_postgres_password}@mattermost-dev-postgres:5432/mattermost?sslmode=disable&connect_timeout=10"

    kubectl -n mattermost create secret generic "${DB_EXTERNAL_SECRET}" \
      --from-literal=DEV_POSTGRES_PASSWORD="${dev_postgres_password}" \
      --from-literal=DB_CONNECTION_STRING="${dev_postgres_dsn}" \
      --from-literal=MM_SQLSETTINGS_DRIVERNAME=postgres \
      --from-literal=MM_SQLSETTINGS_DATASOURCE="${dev_postgres_dsn}"
  fi

  kubectl apply -f gcp/dev-postgres.yaml
  kubectl -n mattermost rollout status statefulset/mattermost-dev-postgres --timeout=180s
else
  sed \
    -e "s|__DB_SECRET_ID__|${DB_SECRET_ID}|g" \
    -e "s|__DB_EXTERNAL_SECRET__|${DB_EXTERNAL_SECRET}|g" \
    gcp/db-externalsecret.yaml >/tmp/db-externalsecret.yaml

  kubectl apply -f /tmp/db-externalsecret.yaml
  kubectl -n mattermost wait "externalsecret/${DB_EXTERNAL_SECRET}" --for=condition=Ready --timeout=180s
fi
if [[ "${DEPLOY_MATTERBRIDGE}" == "true" ]]; then
  if ! kubectl -n mattermost wait externalsecret/matterbridge --for=condition=Ready --timeout=30s; then
    echo "matterbridge ExternalSecret is not ready yet; create the matterbridge-* GCP secrets to start the bridge."
  fi
fi

helm upgrade -i mattermost \
  -n mattermost \
  --create-namespace \
  -f operator.yaml \
  mattermost/mattermost-operator \
  --wait

if [[ -f clusterissuer.yaml ]]; then
  kubectl apply -f clusterissuer.yaml
fi

if [[ -f certs.yaml ]]; then
  kubectl apply -n mattermost -f certs.yaml
fi

sed \
  -e "s|^  name: .*|  name: ${MATTERMOST_NAME}|" \
  -e "s|^  image: .*|  image: ${IMAGE_REPO}|" \
  -e "s|^  version: .*|  version: ${IMAGE_TAG}|" \
  -e "s|host: .*|host: ${INGRESS_HOST}|" \
  -e "s|tlsSecret: .*|tlsSecret: \"${TLS_SECRET}\"|" \
  -e "s|secret: postgres-connection|secret: ${DB_EXTERNAL_SECRET}|" \
  -e "s|secret: s3-credentials|secret: ${S3_EXTERNAL_SECRET}|" \
  -e "s|bucket: .*|bucket: ${BUCKET_NAME}|" \
  -e "/name: MM_SERVICESETTINGS_SITEURL/{n;s|value: .*|value: \"${SITE_URL}\"|}" \
  mattermost.yaml >/tmp/mattermost.yaml

kubectl apply -n mattermost -f /tmp/mattermost.yaml
sed \
  -e "s|name: mattermost|name: ${INGRESS_NAME}|" \
  -e "s|yourown.chat|${INGRESS_HOST}|g" \
  -e "s|yourown-chat-tls|${TLS_SECRET}|g" \
  -e "s|name: yourown-chat|name: ${MATTERMOST_NAME}|g" \
  ingress.yaml >/tmp/ingress.yaml

kubectl apply -n mattermost -f /tmp/ingress.yaml
if [[ "${DEPLOY_MATTERBRIDGE}" == "true" ]]; then
  kubectl apply -n mattermost -f matterbridge.yaml
fi
kubectl -n mattermost get mattermost,pods,svc,endpoints || true