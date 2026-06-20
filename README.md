# YourOwn.Chat RKE2 deploy config

Cloud Build deploys this repository into the RKE2 VM created by Terragrunt. It
reads only the kubeconfig from Secret Manager. Application secrets stay in GCP
Secret Manager and are synced into Kubernetes by External Secrets Operator.

The deploy installs:

- External Secrets Operator
- cert-manager
- ingress-nginx
- Mattermost Operator and the Mattermost custom resource

Mattermost integration settings are hardened in the Helm chart: personal
access tokens are disabled, incoming webhooks are enforced as locked to their
configured channel, outgoing webhooks remain enabled because Mattermost only
allows them in public channels, and username/icon overrides plus bot account
creation are disabled. Create the CI/CD incoming webhook against a public channel;
Mattermost does not provide an environment setting that makes incoming webhooks
public-channel-only by itself.

Cloud Build packages the chart from `helm/yourown-chat`, pushes it as an OCI
Helm chart to Artifact Registry, then deploys that exact chart version.

Runtime secrets expected in GCP Secret Manager:

- `mattermost-db-datasource`
- `mattermost-s3-access-key`
- `mattermost-s3-secret-key`

Matterbridge is deployed as an optional workload. Terragrunt creates these GCP
Secret Manager entries; add secret versions before expecting the bridge pod to
start:

- `matterbridge-local-mattermost-token`
- `matterbridge-local-mattermost-team`
- `matterbridge-local-mattermost-channel`
- `matterbridge-external-mattermost-server`
- `matterbridge-external-mattermost-team`
- `matterbridge-external-mattermost-token`
- `matterbridge-external-mattermost-channel`
- `matterbridge-rocketchat-server`
- `matterbridge-rocketchat-user-id`
- `matterbridge-rocketchat-token`
- `matterbridge-rocketchat-channel`
- `matterbridge-telegram-token`
- `matterbridge-telegram-chat-id`

```sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PROJECT_ID=gcloud-production-1
export IMAGE_REPO=southamerica-east1-docker.pkg.dev/gcloud-production-1/mattermost/mattermost
export IMAGE_TAG=0.1.0
export CHART_REPOSITORY=oci://southamerica-east1-docker.pkg.dev/gcloud-production-1/mattermost
export TAG_NAME=0.1.0
export BUCKET_NAME=gcloud-production-1-mattermost-southamerica-east1
export SITE_URL=https://yourown.chat

make deploy
```