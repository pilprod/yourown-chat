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

The first stage (`dev` target) auto-deploys Mattermost and Postgres into the
shared `dev` namespace. Matterbridge remains isolated in its own namespace and
is deployed when `matterbridge_enabled = true` (through a separate Skaffold
profile; set it false to skip the bridge),
then runs the post-deploy **verify** job on the cluster — a curl against
`dev-mattermost.dev.svc:8065/api/v4/system/ping` from inside the `dev`
namespace (it must run there: the namespace is default-deny). If verify fails,
the release is marked failed and prod is never offered.

### 4. prod waits for a human

The `prod` target has `requireApproval = true`. In **Cloud Deploy →
europe-west3 → releases**, review and **Approve** (or reject) the promotion.
On approval the operator-managed prod Mattermost and enabled MCP workloads
roll out. When MCP is enabled, an in-cluster verify Job checks all three health
endpoints, performs MCP initialization against Terraform and Google Cloud, and
confirms that Google Workspace enforces OAuth. A failed check marks the rollout
unsuccessful.

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
skipped). The namespaces and the credential Secrets (`dev-postgres`,
`mattermost-db`, `mattermost-filestore`) are created by the app-gcp
`cluster_secrets` component — apply that stack first, or create them by hand:

```bash
kubectl apply -f helm/developing/     # dev tenant (dev-postgres Secret already exists)
kubectl apply -f helm/matterbridge/   # optional bridge in its isolated namespace
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
   - the dev-team RBAC subjects: set `dev_team_rbac_subjects` in the app-gcp
     deployment (e.g. `[{ kind = "Group", name = "dev-team@example.com" }]`).
     Terraform creates the `dev-tenant` Role/RoleBinding in the `dev` namespace
     (Cloud Deploy's execution SA can't manage RBAC). Empty = no dev-team RBAC.

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
| `prod` | `e2-standard-2` | `dedicated=prod:NoSchedule` | prod Mattermost |
| `dev`  | `e2-medium`, autoscale 1–3 | none | dev Mattermost, in-cluster Postgres, matterbridge, kube-system |

Prod workloads carry `nodeSelector: {tier: prod}` **and** a matching
toleration, so they can only land on the isolated prod pool. Dev/bridge
workloads carry `nodeSelector: {tier: dev}` and no toleration, so they stay
off prod.

## Secrets — everything via Secret Manager

No credential is committed or placed in a ConfigMap. Two delivery paths:
- **file mount** via the GKE Secret Manager CSI add-on — used by matterbridge
  (`matterbridge.toml`), the one thing that reads a mounted file;
- **Kubernetes Secret created directly in etcd by Terraform** — everything a
  controller consumes via `secretKeyRef`/`tlsSecret` (the Mattermost operator,
  the ingress), because the managed add-on can't sync `secretObjects` (see the
  note below).

| Secret Manager secret | Consumed by | As |
|-----------------------|-------------|----|
| `cloudsql-mattermost-connection` | prod Mattermost | Secret `mattermost-db` → `DB_CONNECTION_STRING`, created directly in etcd by Terraform (`cluster_secrets`, value read from Secret Manager) |
| `mattermost-storage-access-key` / `-secret-key` | prod Mattermost | Secret `mattermost-filestore` → `accesskey`/`secretkey`, created the same way |
| `dev-postgres-password` | dev Postgres / dev Mattermost | Secret `dev-postgres` → `POSTGRES_PASSWORD`, created directly in etcd by Terraform (`cluster_secrets`, generated value) — not CSI (see note below) |
| `matterbridge-tokens` | matterbridge | file `/etc/matterbridge/matterbridge.toml` |
| `mattermost-origin-tls-cert` / `-key` | prod Mattermost Ingress | Secret `mattermost-origin-tls` → `tls.crt`/`tls.key`, created in etcd by Terraform (`cluster_secrets`) from the cloudflare-written values (app-gcp runs after cloudflare) |
| `cloudflare-origin-pull-ca` | prod Mattermost Ingress (AOP mTLS) | Secret `cloudflare-origin-pull-ca` → `ca.crt`, created by Terraform **only when `aop_enabled`** |

> ⚠️ **Managed add-on limitation — `secretObjects` is not supported.** The
> cluster runs the **managed** GKE Secret Manager add-on
> (`secret_manager_config`), which mounts secrets as files but **cannot sync
> them into Kubernetes Secret objects** (the open-source driver's `secretObjects`
> feature). So every credential the operator/pods consume as a Kubernetes Secret
> is created **directly in etcd by Terraform** (the app-gcp `cluster_secrets`
> component, via the `kubernetes` provider), NOT via CSI and NOT through Cloud
> Deploy — the values never land in a deploy parameter or a release render.
> Terraform also owns the tenant namespaces (so the Secrets exist before Cloud
> Deploy deploys workloads). There is no `SecretProviderClass` and no
> `secret-sync` Deployment. The Secrets:
> - `dev-postgres` (generated password);
> - `mattermost-db`, `mattermost-filestore` (read back from Secret Manager);
> - `mattermost-origin-tls` (Origin CA cert/key), **only when
>   `manage_ingress_origin_tls`** — the cert/key are read from the values the
>   **cloudflare** stack writes, so apply cloudflare FIRST, then flip
>   `manage_ingress_origin_tls = true` and re-apply app-gcp (default false so a
>   first apply never 404s on a not-yet-created secret; the two stacks are not
>   linked — order them by hand);
> - `cloudflare-origin-pull-ca` (AOP client-cert CA), **only when `aop_enabled`**.
>
> All values live only in Terraform state (HCP, encrypted) and etcd, and **etcd
> itself is CMEK-encrypted** (application-layer Secrets encryption, see above).
>
> **AOP (Authenticated Origin Pulls):** off by default. The ingress
> `auth-tls-verify-client` annotation is driven by the `aop_verify_client` deploy
> parameter (`off` → Full (Strict) TLS only, `on` → enforce client-cert mTLS).
> To enable: set `aop_enabled = true` in the app-gcp deployment **and**
> `cloudflare_aop_enabled = true` in the cloudflare stack, and load the AOP CA
> into the `cloudflare-origin-pull-ca` Secret Manager secret out-of-band.

> **After a DB password rotation**: `kubectl rollout restart -n mattermost deploy`
> — pods pick up the updated Secret on restart, not live.
