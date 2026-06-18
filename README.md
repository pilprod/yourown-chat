# YourOwn.Chat RKE2 deploy config

Cloud Build deploys this repository into the RKE2 VM created by Terragrunt. It
reads only the kubeconfig from Secret Manager. Application secrets stay in GCP
Secret Manager and are synced into Kubernetes by External Secrets Operator.

The deploy installs:

- External Secrets Operator
- cert-manager
- ingress-nginx
- Mattermost Operator and the Mattermost custom resource

Lightweight Prometheus monitoring is present in the deploy script but commented
out for now.

Runtime secrets expected in GCP Secret Manager:

- `mattermost-db-datasource`
- `mattermost-s3-access-key`
- `mattermost-s3-secret-key`

```sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PROJECT_ID=gcloud-production-1
export BUCKET_NAME=gcloud-production-1-mattermost-southamerica-east1
export SITE_URL=https://yourown.chat

bash gcp/deploy.sh
```