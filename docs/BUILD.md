# Build stack bootstrap (unified registry + Mattermost image CI)

The **build stack** (`stacks/build`) is a second, independent Terraform Stacks
configuration that owns the **unified container registry** and builds the
Mattermost image with Cloud Build. It is separate from the platform stack so the
registry + image CI have their own lifecycle, permissions and blast radius, and
so a single cross-environment registry has a natural home (a per-environment
platform deployment has nowhere to put a shared singleton).

```
git tag on github.com/pilprod/mattermost
  ^v.*-patched$      ─► Cloud Build ─► europe-west3-docker.pkg.dev/yourown-chat/ycs-containers/mattermost:<tag>   (prod)
  ^v.*patched-dev$   ─► Cloud Build ─► europe-west3-docker.pkg.dev/yourown-chat/ycs-containers/mattermost:<tag>   (dev)
```

Both tag patterns push the **same image path**; they differ only by tag, so the
artifact is promoted dev->prod, not duplicated per environment.

What the stack creates:

- **one unified Artifact Registry repository** `ycs-containers` (Docker,
  `europe-west3`), via the `artifact-registry` module;
- one Cloud Build **2nd-gen GitHub connection** + repository link to
  `pilprod/mattermost`, via the `cloudbuild-image` module;
- a dedicated least-privilege **build service account**
  (`ycs-img-build@yourown-chat.iam.gserviceaccount.com`) with only
  `logging.logWriter` (project) and `artifactregistry.writer` (scoped to the one
  `ycs-containers` repo);
- two **tag-triggered** builds (prod + dev) that run `docker build -f Dockerfile .`
  and push the tagged image.

Authentication is the same keyless path as the platform stack (HCP OIDC -> WIF
-> apply-SA impersonation) and reuses the **same shared `terraform-apply@` SA**
(a single plan/apply account for both stacks, per
[`google_cloud_init.md`](google_cloud_init.md)); it just needs a few extra
build-specific roles (step 3). No dedicated build SA, no static credentials, no
SA keys.

---

## 0. Prerequisites

- The **platform stack is applied first**. It enables the Cloud Build and
  Artifact Registry APIs (its `project-services` component) that this stack uses.
  This stack does not enable APIs; it creates the registry and CI on top.
- The WIF pool/provider from [`google_cloud_init.md`](google_cloud_init.md)
  already exist (`hcp-terraform` / `hcp-terraform`) and trust the `papou-work`
  HCP org + `yourown-chat` HCP project. The build HCP Stack must live in that
  same HCP org/project so the existing provider trusts its tokens.
- `PROJECT_ID=yourown-chat`, `PROJECT_NUMBER=1086706391144`.
- The Mattermost source lives at `https://github.com/pilprod/mattermost` with a
  `Dockerfile` at the repository root.

## 1. Store the GitHub PAT in Secret Manager

The 2nd-gen connection authenticates to GitHub with a fine-grained PAT. Create
it out-of-band and store it in Secret Manager (never in git). The secret's short
ID is passed to the stack as `github_pat_secret_id` (default `github-pat`).

Required PAT scopes (fine-grained, on the `pilprod/mattermost` repo):
`Contents: Read-only`, `Metadata: Read-only`, `Webhooks: Read and write`,
`Commit statuses: Read and write`, `Pull requests: Read and write`.

```bash
export PROJECT_ID="yourown-chat"

printf '%s' "<PASTE_GITHUB_PAT>" | gcloud secrets create github-pat \
  --project="$PROJECT_ID" \
  --replication-policy="user-managed" --locations="europe-west3" \
  --data-file=-
# Rotate later with: gcloud secrets versions add github-pat --data-file=-
```

The module grants the Cloud Build service agent
(`service-1086706391144@gcp-sa-cloudbuild.iam.gserviceaccount.com`)
`secretmanager.secretAccessor` on this secret automatically.

## 2. Authorize the Cloud Build GitHub App (one-time OAuth)

The 2nd-gen connection requires the Cloud Build GitHub App to be installed on
the account/org that owns `pilprod/mattermost`. This OAuth handshake cannot be
done in Terraform. Do it once, then read the installation ID:

1. In the Google Cloud console: **Cloud Build -> Repositories -> 2nd gen ->
   Create host connection**, region **europe-west3**, provider **GitHub**, and
   complete the "Authorize" + "Install" flow for the `pilprod` account.
   (You may cancel before it creates a console-managed connection; Terraform
   creates the connection resource. The goal here is only to install the App and
   obtain the installation ID.)
2. Find the installation ID in the GitHub App installation URL
   (`https://github.com/settings/installations/<INSTALLATION_ID>`), or via the
   API. Set it as `github_app_installation_id`.

## 3. Grant the shared apply SA the extra build roles

The build stack reuses the **same** `terraform-apply@` SA the platform stack
impersonates (single plan/apply account, per `google_cloud_init.md`). Its WIF
binding already exists (the org-scoped `principalSet` created in
`google_cloud_init.md` step 6), so **no new SA and no new WIF binding are
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

- `artifactregistry.admin` — create the `ycs-containers` repo and grant the
  build SA `writer` on it.
- `cloudbuild.connectionAdmin` — create the 2nd-gen connection + repository.
- `cloudbuild.builds.editor` — create the triggers.
- `resourcemanager.projectIamAdmin` — grant the build SA project-level
  `logging.logWriter`.
- `serviceusage.serviceUsageAdmin` — create the Cloud Build service identity
  (`google_project_service_identity`, beta).

`secretmanager.admin` (PAT accessor binding) and `iam.serviceAccountAdmin` +
`iam.serviceAccountUser` (create the build SA and `actAs` it) are already granted
to `terraform-apply@` in `google_cloud_init.md`. `projectIamAdmin` and
`serviceUsageAdmin` are also required by the platform stack (its own project IAM
bindings + API enablement), so they may already be present — re-granting is a
no-op.

> Start here to keep the first apply unblocked without granting Owner/Editor;
> tighten later by swapping project roles for resource-scoped IAM conditions once
> names stabilise.

## 4. Fill the deployment inputs

In `stacks/build/deployments.tfdeploy.hcl`, the `build` deployment is already
wired for `yourown-chat` and impersonates the shared `terraform-apply@` SA. Set
the one real value from step 2:

- `github_app_installation_id` -> the installation ID (**numeric**; replace the
  `0` sentinel in the `build` deployment). A `> 0` validation blocks the plan
  until it is set.
- `github_pat_secret_id` -> `github-pat` (default; change only if you named it
  differently).

The `builds` map is **tag-routing only** — both entries push to the unified
`ycs-containers` repo (`artifact_registry_repository_id`, default `ycs-containers`)
and differ only by the git tag regex.

## 5. Create the Stack in HCP Terraform

1. Create a **second** HCP Stack (e.g. `yourown-chat-eu-build`) in the **same**
   HCP org/project (`papou-work` / `yourown-chat`) with its **working directory
   set to `stacks/build`**, connected to this repo.
2. It reuses the same WIF pool/provider; the build deployment selects the shared
   `terraform-apply@` SA via its `service_account_email` input.
3. Plan and apply **after** the platform stack.

## 6. Build an image

Tag a release in `github.com/pilprod/mattermost`:

```bash
# prod image
git tag v9.11.3-patched && git push origin v9.11.3-patched
# dev image
git tag v9.11.3-patched-dev && git push origin v9.11.3-patched-dev
```

Cloud Build fires the matching trigger and pushes the image. Verify:

```bash
gcloud artifacts docker images list \
  europe-west3-docker.pkg.dev/yourown-chat/ycs-containers/mattermost \
  --project=yourown-chat
```

## 7. Reference the image in the workloads

Already wired in the manifests (change the tag to the one you pushed):

- **prod** `helm/mattermost/mattermost.yaml`:
  `spec.image: europe-west3-docker.pkg.dev/yourown-chat/ycs-containers/mattermost`,
  `spec.version: v9.11.3-patched` (the operator builds `image:version`).
- **dev** `helm/dev/mattermost-dev.yaml`:
  `image: europe-west3-docker.pkg.dev/yourown-chat/ycs-containers/mattermost:v9.11.3-patched-dev`.

## Notes

- **One repo, promote by tag.** prod and dev share `ycs-containers/mattermost`;
  the tag is the only difference. This is the foundation for the follow-up Cloud
  Deploy dev->prod promotion pipeline (build once, promote the same artifact).
- **Tag patterns are disjoint.** `^v.*-patched$` matches `v9.11.3-patched` only
  (ends with `-patched`); `^v.*patched-dev$` matches `v9.11.3-patched-dev` only
  (ends with `patched-dev`). A dev tag never fires the prod build and vice versa.
- **APIs come from the platform stack.** Apply it first; the build stack creates
  the registry + CI but enables no APIs itself.
- **Rotating the PAT** is a `gcloud secrets versions add github-pat` away; the
  connection reads `versions/latest`.
