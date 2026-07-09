# Platform workloads (GitOps)

Kubernetes manifests for the chat platform, kept **separate from infrastructure**
(Terraform) and from the sample CI/CD app in [`../app`](../app). Apply these with
your GitOps controller (Argo CD / Flux) or `kubectl apply -f` per directory.

## Topology & scheduling

One zonal GKE cluster, two node pools (provisioned by Terraform):

| Node pool | Machine | Taint | Runs |
|-----------|---------|-------|------|
| `prod` | `e2-standard-2` | `dedicated=prod:NoSchedule` | prod Mattermost (+ its secret-sync) |
| `dev`  | `e2-small` | none | dev Mattermost, in-cluster Postgres, matterbridge, kube-system |

Prod workloads carry `nodeSelector: {tier: prod}` **and** a matching toleration,
so they can only land on the isolated prod pool. Dev/bridge workloads carry
`nodeSelector: {tier: dev}` and no toleration, so they stay off prod.

## Secrets — everything via Secret Manager

No credential is committed or placed in a ConfigMap. The GKE **Secret Manager
CSI add-on** (enabled by Terraform) mounts secrets into pods; `secretObjects`
mirror them into Kubernetes Secrets where a controller (the Mattermost operator)
needs a `secretKeyRef`.

| Secret Manager secret | Consumed by | As |
|-----------------------|-------------|----|
| `ycs-prod-cloudsql-mattermost-connection` | prod Mattermost | Secret `mattermost-db` → `DB_CONNECTION_STRING` |
| `ycs-prod-app-filestore-access-key` / `-secret-key` | prod Mattermost | Secret `mattermost-filestore` → `accesskey`/`secretkey` |
| `ycs-prod-dev-postgres-password` | dev Postgres / dev Mattermost | file `POSTGRES_PASSWORD_FILE` + Secret `dev-postgres` |
| `ycs-prod-matterbridge-tokens` | matterbridge | file `/etc/matterbridge/matterbridge.toml` |

Secret **values** are created by Terraform (generated) or populated out-of-band:

```bash
# matterbridge config (contains tokens) — created empty by Terraform:
gcloud secrets versions add ycs-prod-matterbridge-tokens --data-file=matterbridge.toml
```

## Prerequisites

1. Cluster is up with the Secret Manager CSI add-on (Terraform `gke` component).
2. Workload Identity bindings exist (Terraform `workload-identity` components).
   Replace every `iam.gke.io/gcp-service-account` annotation with the exact email
   from `terraform output workload_identity_emails`.
3. Install the ingress-nginx controller and the **Mattermost Operator** + CRDs:
   ```bash
   helm repo add mattermost https://helm.mattermost.com && helm repo update
   helm upgrade --install mattermost-operator mattermost/mattermost-operator -n mattermost-operator --create-namespace
   ```
4. Replace all `REPLACE-ME-*` markers (project ID, bucket, hostnames, image
   versions). The bucket name is `terraform output gcs_bucket_name`.

## Apply order

```bash
kubectl apply -f namespaces.yaml
kubectl apply -f dev/            # in-cluster Postgres materialises dev-postgres Secret first
kubectl apply -f matterbridge/
kubectl apply -f mattermost/     # operator CRDs must already be installed
```
