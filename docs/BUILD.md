# Image CI (unified registry + Mattermost image build)

The container CI is part of the **single Terraform Stack** at `terraform/`
(working directory `terraform/`). It is not a separate stack — the
`artifact_registry` and `mattermost_image` components own the **unified container
registry** and build the Mattermost image with Cloud Build, alongside the
platform and Cloudflare components in the one `prod-eu` deployment.

```
git tag on github.com/pilprod/mattermost
  ^v.*-patched$   ─► Cloud Build ─► europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost:<tag>
```

One tag pattern builds **one image**; that single artifact is promoted dev->prod
(by the `clouddeploy` component's Cloud Deploy pipeline), not rebuilt per
environment.

What the image-CI components create:

- **one unified Artifact Registry repository** `docker` (Docker, `europe-west3`),
  via the `artifact-registry` module. The registry is **public**, so it is
  deliberately **not** CMEK-encrypted;
- one Cloud Build **2nd-gen GitHub connection** + repository link to
  `pilprod/mattermost`, via the `cloudbuild-image` module. The connection reads
  the **out-of-band `github-pat` secret** (created in [`INIT.md`](INIT.md)) at
  `versions/latest`;
- a dedicated least-privilege **build service account**
  (`img-build@yourown-chat.iam.gserviceaccount.com`) with only
  `logging.logWriter` (project) and `artifactregistry.writer` (scoped to the one
  `docker` repo);
- one **tag-triggered** build that runs `docker build -f Dockerfile .` and pushes
  the tagged image.

API enablement (`cloudbuild`, `artifactregistry`) is handled by the stack's one
`project_services` component together with every other API. Authentication is the
keyless HCP OIDC -> WIF -> `terraform-apply@` impersonation path shared by the
whole stack (see [`INIT.md`](INIT.md), which also grants the apply SA the
build-specific roles). No static credentials, no SA keys.

---

## 0. Prerequisites

All pre-Terraform setup is done **once** in [`INIT.md`](INIT.md) (the single
source of truth) — do not repeat it here:

- **Bootstrap APIs**, the **WIF pool/provider**, the `terraform-apply@` SA and
  **all its IAM roles** (including the build-specific `artifactregistry.admin`,
  `cloudbuild.connectionAdmin`, `cloudbuild.builds.editor` and
  `serviceusage.serviceUsageAdmin`), and the **`github-pat` secret** + **Cloud
  Build App installation ID**.

Constants used below: `PROJECT_ID=yourown-chat`, `PROJECT_NUMBER=1086706391144`.
The Mattermost source lives at `https://github.com/pilprod/mattermost` with a
`Dockerfile` at the repository root.

## 1. Fill the deployment inputs

In `terraform/deployments.tfdeploy.hcl`, the `prod-eu` deployment is already wired
for `yourown-chat`. Set the one real image-CI value:

- `github_app_installation_id` -> the installation ID from [`INIT.md`](INIT.md)
  (**numeric**; replace the `0` sentinel). A `> 0` validation blocks the plan
  until it is set.
- `github_pat_secret_id` -> `github-pat` (default; change only if you named it
  differently in INIT.md).

The `builds` map has a **single entry** — it pushes to the unified `docker` repo
(`artifact_registry_repository_id`, default `docker`) on the one git tag regex
(`^v.*-patched$`).

## 2. Apply the stack

There is **no separate stack to create** — the registry and image CI are
components of the single stack. Plan and apply the `prod-eu` deployment as
described in [`INIT.md`](INIT.md) §9; the same apply creates the registry, the
Cloud Build connection and the tag trigger along with the rest of the platform.

## 3. Build an image

Tag a release in `github.com/pilprod/mattermost`:

```bash
git tag v9.11.3-patched && git push origin v9.11.3-patched
```

Cloud Build fires the matching trigger and pushes the image. Verify:

```bash
gcloud artifacts docker images list \
  europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost \
  --project=yourown-chat
```

## 4. Reference the image in the workloads

Already wired in the manifests (change the tag to the one you pushed):

- **prod** `helm/mattermost/mattermost.yaml`:
  `spec.image: europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost`,
  `spec.version: v9.11.3-patched` (the operator builds `image:version`).
- **dev** `helm/developing/mattermost-dev.yaml`:
  `image: europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost:v9.11.3-patched`
  (the **same** tag as prod — build once, promote the same image).

## 5. Ship it: cut a release (automated)

Building the image doesn't deploy it — a **release** does. That step is automated
by the `deploy_release` component: push a **semver tag** (`MAJOR.MINOR.PATCH`) to
**this** repo and a Cloud Build trigger runs `gcloud deploy releases create
--source=helm` for you, entering the dev->prod pipeline (dev verify -> prod
approval). No manual `releases create`.

```
git tag 1.4.0 && git push origin 1.4.0
   ─► Cloud Build (2nd-gen) ─► gcloud deploy releases create ─► europe-west3-pipeline
```

Bump the in-manifest image tag first (step 4), commit, then tag the release. The
release promotes those manifests; it does not rebuild the image. The exact command
lives in [`helm/cloudbuild.yaml`](../helm/cloudbuild.yaml) if you ever need to cut
one by hand.

## Notes

- **Build once, promote the same artifact.** One tag pattern builds one image;
  both Mattermost manifests (dev + prod) reference the SAME
  `docker/mattermost:<tag>` — the image is never rebuilt per environment. The
  `clouddeploy` component delivers these `helm/` manifests as a managed dev->prod
  promotion (dev verify -> prod approval).
- **Single tag pattern.** `^v.*-patched$` matches release tags like
  `v9.11.3-patched`. There is no separate dev image or dev tag.
- **No CMEK owned here.** The public registry is not CMEK-encrypted, and the
  image-CI components own no Cloud KMS key. The `github-pat` secret *is*
  CMEK-encrypted, but by a dedicated **bootstrap** key created by hand in INIT.md
  §8.2 (it predates the stack), not by these components.
- **One PAT, two connections.** The same `github-pat` backs both the image
  connection (`pilprod/mattermost`) and the release connection
  (`pilprod/yourown-chat`); scope it to both repos (INIT.md §8). Rotating it is a
  `gcloud secrets versions add github-pat` away; both connections read
  `versions/latest`.
