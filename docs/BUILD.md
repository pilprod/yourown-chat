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
(a single plan/apply account for both stacks, per [`INIT.md`](INIT.md)); it just
needs a few extra build-specific roles (step 2). No dedicated build SA, no static
credentials, no SA keys.

---

## 0. Prerequisites

Everything shared is provisioned once, out-of-band, in [`INIT.md`](INIT.md), so
this stack has **no dependency on the platform stack** and the two can be applied
in **any order**:

- **APIs** (Cloud Build, Artifact Registry, Secret Manager, ...) are enabled in
  [`INIT.md`](INIT.md) step 2. Neither stack manages APIs.
- The **`github-pat` secret** is created and populated in [`INIT.md`](INIT.md)
  step 8. This stack only **reads** `versions/latest` of it — it does not create,
  encrypt, or own the secret. (Encryption is the secret's own concern; the
  default is Google-managed.)
- The **Cloud Build GitHub App installation ID** is obtained in
  [`INIT.md`](INIT.md) step 8.4.
- The **WIF pool/provider** (`hcp-terraform` / `hcp-terraform`) exist and trust
  the `papou-work` HCP org + `yourown-chat` HCP project. The build HCP Stack must
  live in that same HCP org/project so the existing provider trusts its tokens.
- `PROJECT_ID=yourown-chat`, `PROJECT_NUMBER=1086706391144`.
- The Mattermost source lives at `https://github.com/pilprod/mattermost` with a
  `Dockerfile` at the repository root.

## 1. Confirm the GitHub PAT + installation ID (from INIT.md)

The 2nd-gen connection authenticates to GitHub with the fine-grained `github-pat`
secret created in [`INIT.md`](INIT.md) step 8. Because the connection reads
`versions/latest` when it is applied, that version must already exist — which it
does after INIT.md. No secret is created here and there is **no two-pass apply**.

The module grants the Cloud Build service agent
(`service-1086706391144@gcp-sa-cloudbuild.iam.gserviceaccount.com`)
`secretmanager.secretAccessor` on the secret automatically.

Have the numeric `github_app_installation_id` from [`INIT.md`](INIT.md) step 8.4
ready for step 3.

## 2. Grant the shared apply SA the extra build roles

The build stack reuses the **same** `terraform-apply@` SA the platform stack
impersonates (single plan/apply account, per [`INIT.md`](INIT.md)). Its WIF
binding already exists (the org-scoped `principalSet` created in
[`INIT.md`](INIT.md) step 6), so **no new SA and no new WIF binding are
needed** — only a few extra project roles for the build resources.

```bash
export PROJECT_ID="yourown-chat"
export APPLY_SA="terraform-apply@${PROJECT_ID}.iam.gserviceaccount.com"

# Extra roles the build stack needs on the shared apply SA (idempotent).
for ROLE in \
  roles/artifactregistry.admin \
  roles/cloudbuild.connectionAdmin \
  roles/cloudbuild.builds.editor \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin ; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${APPLY_SA}" --role="$ROLE" --condition=None
done
```

Why each role:

- `artifactregistry.admin` — create the `docker` repo and grant the
  build SA `writer` on it.
- `cloudbuild.connectionAdmin` — create the 2nd-gen connection + repository.
- `cloudbuild.builds.editor` — create the triggers.
- `resourcemanager.projectIamAdmin` — grant the build SA project-level
  `logging.logWriter`.
- `serviceusage.serviceUsageAdmin` — create the Cloud Build service identity
  (`google_project_service_identity`, beta).

`secretmanager.admin` (grant the Cloud Build agent `secretAccessor` on the
`github-pat` secret) and `iam.serviceAccountAdmin` + `iam.serviceAccountUser`
(create the build SA and `actAs` it) are already granted to `terraform-apply@` in
[`INIT.md`](INIT.md). `projectIamAdmin` and `serviceUsageAdmin` are also required
by the platform stack, so they may already be present — re-granting is a no-op.

> Start here to keep the first apply unblocked without granting Owner/Editor;
> tighten later by swapping project roles for resource-scoped IAM conditions once
> names stabilise.

## 3. Fill the deployment inputs

In `terraform/build/deployments.tfdeploy.hcl`, the `build` deployment is already
wired for `yourown-chat` and impersonates the shared `terraform-apply@` SA. Set
the one real value:

- `github_app_installation_id` -> the installation ID from
  [`INIT.md`](INIT.md) step 8.4 (**numeric**; replace the `0` sentinel in the
  `build` deployment). A `> 0` validation blocks the plan until it is set.
- `github_pat_secret_id` -> `github-pat` (default; change only if you named it
  differently in INIT.md).

The `builds` map has a **single entry** — it pushes to the unified
`docker` repo (`artifact_registry_repository_id`, default `docker`)
on the one git tag regex (`^v.*-patched$`).

## 4. Create the Stack in HCP Terraform

1. Create a **second** HCP Stack (e.g. `yourown-chat-eu-build`) in the **same**
   HCP org/project (`papou-work` / `yourown-chat`) with its **working directory
   set to `terraform/build`**, connected to this repo.
2. It reuses the same WIF pool/provider; the build deployment selects the shared
   `terraform-apply@` SA via its `service_account_email` input.
3. Plan and apply. Because APIs and the PAT secret come from
   [`INIT.md`](INIT.md), this stack can be applied **independently** of the
   platform stack (any order).

## 5. Build an image

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

## 6. Reference the image in the workloads

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
- **APIs + PAT come from INIT.md.** This stack enables no APIs and creates no
  secret; both are provisioned once in [`INIT.md`](INIT.md), which makes the build
  and platform stacks independent (apply in any order).
- **No CMEK here.** The public registry is not CMEK-encrypted, and the
  `github-pat` secret's encryption is its own concern (Google-managed by default,
  set in INIT.md). The build stack owns no Cloud KMS key.
- **Rotating the PAT** is a `gcloud secrets versions add github-pat` away; the
  connection reads `versions/latest`.
