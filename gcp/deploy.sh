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

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required environment variable: ${var_name}" >&2
    exit 1
  fi
done

echo "Deploying Mattermost image ${IMAGE_REPO}:${IMAGE_TAG}"
gcloud artifacts docker images describe "${IMAGE_REPO}:${IMAGE_TAG}" >/dev/null

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

helm upgrade -i cert-manager \
  -n cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set installCRDs=true \
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
  ingress-nginx/ingress-nginx \
  --wait

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
  gcp/externalsecrets.yaml >/tmp/externalsecrets.yaml

kubectl apply -f /tmp/externalsecrets.yaml
kubectl -n mattermost wait externalsecret/postgres-connection --for=condition=Ready --timeout=180s
kubectl -n mattermost wait externalsecret/s3-credentials --for=condition=Ready --timeout=180s

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
  -e "s|^  image: .*|  image: ${IMAGE_REPO}|" \
  -e "s|^  version: .*|  version: ${IMAGE_TAG}|" \
  -e "s|bucket: .*|bucket: ${BUCKET_NAME}|" \
  -e "/name: MM_SERVICESETTINGS_SITEURL/{n;s|value: .*|value: \"${SITE_URL}\"|}" \
  mattermost.yaml >/tmp/mattermost.yaml

kubectl apply -n mattermost -f /tmp/mattermost.yaml
kubectl -n mattermost wait mattermost/yourown-chat --for=condition=Ready --timeout=600s || true

kubectl apply -n mattermost -f ingress.yaml