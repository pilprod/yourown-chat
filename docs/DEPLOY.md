# Deploying the platform workloads

How the chat workloads under [`helm/`](../helm/) get onto the cluster: the
one-time setup, the **full release process** (image → version bump → semver tag
→ verify → approval), and the manual fallbacks.

Infrastructure (Terraform) and workloads (Kubernetes manifests) are kept
strictly apart: Terraform provisions the rails — the Cloud Deploy pipeline, the
build triggers, the secrets — and releases run on those rails without touching
Terraform.

---

## The release model in one picture

```
pilprod/mattermost                         pilprod/yourown-chat (this repo)
──────────────────                         ────────────────────────────────
git tag v9.11.3-patched                    edit helm/: bump version pin, tweak manifests
        │                                          │  (ordinary PR + merge)
        ▼                                          ▼
Cloud Build trigger "mattermost-image"     git tag 1.2.3
  builds Dockerfile                                │
  pushes docker/mattermost:v9.11.3-patched         ▼
        (image now EXISTS)                 Cloud Build trigger "release"
                                             gcloud deploy releases create --source=helm
                                                   │
                                                   ▼
                                           Cloud Deploy pipeline europe-west3
                                             render (skaffold + deploy parameters)
                                                   │
                                        ┌──────────┴──────────┐
                                        ▼                     │ promote
                                   dev target                 ▼
                                   auto-deploy           prod target
                                   + verify job          MANUAL APPROVAL
                                   (smoke test)          then deploy
```

Two independent tags with two different jobs:

| Tag | Repo | Pattern | Meaning |
|---|---|---|---|
| **image tag** | `pilprod/mattermost` | `^v.*-patched$` | "this image now exists in the registry" |
| **release tag** | `pilprod/yourown-chat` | `MAJOR.MINOR.PATCH` | "deploy the manifests as committed right now" |

The link between them is a **committed version pin** in the manifests — an
image is never deployed just because it was built (build once, promote the
same artifact; nothing is rebuilt per environment).

## The full release process

### 0. (When updating Mattermost) build the image

```bash
# in pilprod/mattermost:
git tag v9.11.3-patched && git push origin v9.11.3-patched
```

The `mattermost-image` Cloud Build trigger builds the root `Dockerfile` and
pushes `europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost:v9.11.3-patched`
(tag = `$TAG_NAME`, 1:1). Wait for the build to go green
(**Cloud Build → History**) — the release step does not check that the image
exists. Details: [BUILD.md](BUILD.md).

### 1. Pin the version in the manifests

The image tag is referenced literally in **two files** (Skaffold tag
substitution is deliberately off — the prod operator CR splits the reference
into `spec.image` + `spec.version`, which defeats it):

- `helm/mattermost/mattermost.yaml` → `spec.version: "v9.11.3-patched"`
- `helm/developing/mattermost-dev.yaml` → `image: "...:v9.11.3-patched"`

Open an ordinary PR, review, merge. Any other manifest change (resources,
ingress annotations, NetworkPolicies…) ships the same way — steps 0–1 are
skipped entirely when nothing about the image changes.

### 2. Cut the release — one tag

```bash
# in this repo, on main:
git tag 1.2.3 && git push origin 1.2.3
```

The `release` Cloud Build trigger fires on `^[0-9]+\.[0-9]+\.[0-9]+$` and runs
`gcloud deploy releases create --source=helm` as the least-privilege
`releaser-europe-west3` SA (can create releases on this pipeline only). The
release is named `rel-1-2-3` and annotated with the git tag for traceability.

**Rendering happens now**: Skaffold renders each stage's profile and Cloud
Deploy substitutes the **deploy parameters** — the Terraform-published values
(`filestore_bucket`, the three Workload Identity emails) replace the
`# from-param:` placeholders. A release is a frozen snapshot: manifest or
parameter changes after this point affect the *next* release, not this one.

### 3. dev deploys automatically, then verifies itself

The first stage (`dev` target) auto-deploys the dev tenant + matterbridge,
then runs the post-deploy **verify** job on the cluster — a curl against
`dev-mattermost.dev.svc:8065/api/v4/system/ping` from inside the `dev`
namespace (it must run there: the namespace is default-deny). If verify fails,
the release is marked failed and prod is never offered.

### 4. prod waits for a human

The `prod` target has `requireApproval = true`. In **Cloud Deploy →
europe-west3 → releases**, review and **Approve** (or reject) the promotion.
On approval the operator-managed prod Mattermost rolls out.

```bash
# CLI alternative:
gcloud deploy releases promote --release=rel-1-2-3 \
  --delivery-pipeline=europe-west3 --region=europe-west3
```

### 5. Rollback = redeploy a previous release

```bash
gcloud deploy targets rollback prod-europe-west3 \
  --delivery-pipeline=europe-west3 --region=europe-west3
```

Rollback re-renders the **previous release's** frozen manifests — the git tag
history is the release history, nothing needs reverting in a hurry (revert the
pin in git at leisure and cut the next release).

### Manual fallbacks

Cut a release without a tag (any checkout; needs `clouddeploy.releaser` +
`actAs` on the execution SA):

```bash
gcloud builds submit --config=helm/cloudbuild.yaml .
```

Apply manifests directly with kubectl (bypasses render — the `# from-param:`
placeholders will NOT be substituted, so fill them by hand first; order
matters, and `kubectl apply -f` is non-recursive so the verify Job template is
skipped):

```bash
kubectl apply -f helm/namespaces.yaml
kubectl apply -f helm/developing/     # in-cluster Postgres materialises dev-postgres first
kubectl apply -f helm/matterbridge/
kubectl apply -f helm/mattermost/     # operator CRDs must already be installed
```

---

## One-time setup (before the first release)

1. **Terraform applied**: all three stacks (the `gke` component enables the
   Secret Manager CSI add-on; `workload-identity` creates the per-tenant SAs;
   `clouddeploy` + `deploy-release` create the pipeline and both triggers).
2. **Mattermost Operator and ingress-nginx — installed by Terraform.** The
   app-gcp stack's `cluster_bootstrap` component installs both as
   Terraform-managed Helm releases as soon as the platform cluster exists: the
   helm provider authenticates to the GKE endpoint with a short-lived token
   for the same impersonated apply SA (`roles/container.admin` ⇒
   cluster-admin — no kubeconfig, no extra IAM), and `loadBalancerIP` is
   injected from the platform-published `ingress_ip_address`. Chart versions
   are pinned in `terraform/app-gcp/app.tfdeploy.hcl`. Manual fallback:

   ```bash
   helm repo add mattermost https://helm.mattermost.com && helm repo update
   helm upgrade --install mattermost-operator mattermost/mattermost-operator \
     -n mattermost-operator --create-namespace

   # Public edge, locked to Cloudflare — see ../helm/ingress-nginx/README.md
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
   helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
     -n ingress-nginx --create-namespace -f helm/ingress-nginx/values.yaml
   ```

3. **The one deliberate manual value** (everything else is injected by deploy
   parameters at render time):
   - the dev-team RBAC principal in `helm/developing/rbac.yaml`
     (organizational, not a Terraform value).

   (`loadBalancerIP` in `helm/ingress-nginx/values.yaml` only matters on the
   manual-fallback path above — the Terraform-managed release gets it from the
   platform stack automatically.)
4. **Fill the out-of-band secrets** (Terraform created empty containers):

   ```bash
   # matterbridge config (contains bot tokens) — never in git. Terraform already
   # seeds a default with a DISABLED gateway so the pod starts; add a real config
   # (bot Token/Team, enable=true) to actually bridge the prod Mattermost:
   gcloud secrets versions add matterbridge-tokens --data-file=matterbridge.toml

   # Authenticated Origin Pulls CA (only if cloudflare_aop_enabled):
   gcloud secrets versions add cloudflare-origin-pull-ca --data-file=origin-pull-ca.pem
   ```

   The origin TLS cert/key secrets are filled automatically by the cloudflare
   stack (`cloudflare_manage_origin_cert = true`).
5. **Publish the DNSSEC DS record** at the registrar
   (`terraform output cloudflare_dnssec`).

## Topology & scheduling

One zonal GKE cluster, two node pools (provisioned by Terraform):

| Node pool | Machine | Taint | Runs |
|-----------|---------|-------|------|
| `prod` | `e2-standard-2` | `dedicated=prod:NoSchedule` | prod Mattermost (+ its secret-sync) |
| `dev`  | `e2-medium`, autoscale 1–3 | none | dev Mattermost, in-cluster Postgres, matterbridge, kube-system |

Prod workloads carry `nodeSelector: {tier: prod}` **and** a matching
toleration, so they can only land on the isolated prod pool. Dev/bridge
workloads carry `nodeSelector: {tier: dev}` and no toleration, so they stay
off prod.

## Secrets — everything via Secret Manager

No credential is committed or placed in a ConfigMap. The GKE **Secret Manager
CSI add-on** mounts secrets into pods at start; `secretObjects` mirror them
into Kubernetes Secrets where a controller (the Mattermost operator, ingress)
needs a `secretKeyRef`. Pods read values at runtime — it does not matter which
stack wrote them.

| Secret Manager secret | Consumed by | As |
|-----------------------|-------------|----|
| `cloudsql-mattermost-connection` | prod Mattermost | Secret `mattermost-db` → `DB_CONNECTION_STRING` |
| `mattermost-storage-access-key` / `-secret-key` | prod Mattermost | Secret `mattermost-filestore` → `accesskey`/`secretkey` |
| `dev-postgres-password` | dev Postgres / dev Mattermost | file `POSTGRES_PASSWORD_FILE` + Secret `dev-postgres` |
| `matterbridge-tokens` | matterbridge | file `/etc/matterbridge/matterbridge.toml` |
| `mattermost-origin-tls-cert` / `-key` | ingress-nginx (Mattermost Ingress) | Secret `mattermost-origin-tls` → `tls.crt`/`tls.key` |
| `cloudflare-origin-pull-ca` | ingress-nginx (Mattermost Ingress) | Secret `cloudflare-origin-pull-ca` → `ca.crt` |

Operator-managed pods don't mount the CSI volume themselves, so a tiny
`secret-sync` Deployment (pause container) keeps the volume mounted and the
mirrored Secrets materialised in the `mattermost` namespace.

> **After a DB password rotation** (`cloudsql_password_rotation` bump in
> Terraform): `kubectl rollout restart -n mattermost deploy` — CSI mounts
> refresh on pod start, not live.
