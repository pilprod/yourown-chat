# Build stack bootstrap (unified registry + Mattermost image CI)

The **build stack** (`terraform/build`) is a second, independent Terraform Stacks
configuration that owns the **unified container registry** and builds the
Mattermost image with Cloud Build. It is separate from the platform stack so the
registry + image CI have their own lifecycle, permissions and blast radius, and
so a single cross-environment registry has a natural home (a per-environment
platform deployment has nowhere to put a shared singleton).

```
git tag on github.com/pilprod/mattermost
  ^v.*-patched$   ─► Cloud Build ─► europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost:<tag>
```

One tag pattern builds **one image**; that single artifact is promoted dev->prod
(by the platform stack's Cloud Deploy pipeline), not rebuilt per environment.

What the stack creates:

- **API enablement** for the services this stack owns (`cloudbuild`,
  `artifactregistry`), via its `project_services` component — so it does not rely
  on the platform stack for them;
- **one unified Artifact Registry repository** `docker` (Docker,
  `europe-west3`), via the `artifact-registry` module. The registry is **public**,
  so it is deliberately **not** CMEK-encrypted;
- one Cloud Build **2nd-gen GitHub connection** + repository link to
  `pilprod/mattermost`, via the `cloudbuild-image` module. The connection reads
  the **out-of-band `github-pat` secret** (created in [`INIT.md`](INIT.md)) at
  `versions/latest`;
- a dedicated least-privilege **build service account**
  (`img-build@yourown-chat.iam.gserviceaccount.com`) with only
  `logging.logWriter` (project) and `artifactregistry.writer` (scoped to the one
  `docker` repo);
- one **tag-triggered** build that runs `docker build -f Dockerfile .` and
  pushes the tagged image.

Authentication is the same keyless path as the platform stack (HCP OIDC -> WIF
-> apply-SA impersonation) and reuses the **same shared `terraform-apply@` SA**
(a single plan/apply account for both stacks, per [`INIT.md`](INIT.md), which also
grants it the build-specific roles). No dedicated build SA, no static credentials,
no SA keys.

---

## 0. Prerequisites

All shared, pre-Terraform setup is done **once** in [`INIT.md`](INIT.md) (the
single source of truth) — do not repeat it here:

- **Bootstrap APIs**, the **WIF pool/provider**, the shared `terraform-apply@`
  SA and **all its IAM roles** (including the build-specific
  `artifactregistry.admin`, `cloudbuild.connectionAdmin`,
  `cloudbuild.builds.editor` and `serviceusage.serviceUsageAdmin`), and the
  **`github-pat` secret** + **Cloud Build App installation ID**.

This stack then enables its own APIs (`cloudbuild`, `artifactregistry`) via its
`project_services` component and only **reads** the `github-pat` secret, so it has
**no dependency on the platform stack** — the two can be applied in **any order**.

Constants used below: `PROJECT_ID=yourown-chat`, `PROJECT_NUMBER=1086706391144`.
The Mattermost source lives at `https://github.com/pilprod/mattermost` with a
`Dockerfile` at the repository root.

## 1. Fill the deployment inputs

In `terraform/build/deployments.tfdeploy.hcl`, the `build` deployment is already
wired for `yourown-chat` and impersonates the shared `terraform-apply@` SA. Set
the one real value:

- `github_app_installation_id` -> the installation ID from
  [`INIT.md`](INIT.md) (**numeric**; replace the `0` sentinel in the
  `build` deployment). A `> 0` validation blocks the plan until it is set.
- `github_pat_secret_id` -> `github-pat` (default; change only if you named it
  differently in INIT.md).

The `builds` map has a **single entry** — it pushes to the unified
`docker` repo (`artifact_registry_repository_id`, default `docker`)
on the one git tag regex (`^v.*-patched$`).

## 2. Create the Stack in HCP Terraform

1. Create a **second** HCP Stack (e.g. `yourown-chat-eu-build`) in the **same**
   HCP org/project (`papou-work` / `yourown-chat`) with its **working directory
   set to `terraform/build`**, connected to this repo.
2. It reuses the same WIF pool/provider; the build deployment selects the shared
   `terraform-apply@` SA via its `service_account_email` input.
3. Plan and apply. Because APIs and the PAT secret come from
   [`INIT.md`](INIT.md), this stack can be applied **independently** of the
   platform stack (any order).

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

## Notes

- **Build once, promote the same artifact.** One tag pattern builds one image;
  both Mattermost manifests (dev + prod) reference the SAME
  `docker/mattermost:<tag>` — the image is never rebuilt per environment.
  The platform stack's Cloud Deploy pipeline delivers these `helm/` manifests as a
  managed dev->prod promotion (dev verify -> prod approval).
- **Single tag pattern.** `^v.*-patched$` matches release tags like
  `v9.11.3-patched`. There is no separate dev image or dev tag.
- **This stack enables its own APIs** (`cloudbuild`, `artifactregistry`) and only
  reads the `github-pat` secret. The bootstrap APIs + the PAT secret come from
  [`INIT.md`](INIT.md), so the build and platform stacks are independent (apply in
  any order) with no cross-stack API ownership.
- **No CMEK here.** The public registry is not CMEK-encrypted, and the
  `github-pat` secret's encryption is its own concern (Google-managed by default,
  set in INIT.md). The build stack owns no Cloud KMS key.
- **Rotating the PAT** is a `gcloud secrets versions add github-pat` away; the
  connection reads `versions/latest`.
