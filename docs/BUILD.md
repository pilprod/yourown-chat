# Build stack bootstrap (Mattermost image CI)

The **build stack** (`stacks/build`) is a second, independent Terraform Stacks
configuration that builds the Mattermost container image with Cloud Build and
pushes it to Artifact Registry. It is separate from the platform stack so image
CI has its own lifecycle, permissions and blast radius.

```
git tag on github.com/pilprod/mattermost
  ^v.*-patched$      ─► Cloud Build ─► europe-west3-docker.pkg.dev/yourown-chat/ycs-prod-containers/mattermost:<tag>
  ^v.*patched-dev$   ─► Cloud Build ─► europe-west3-docker.pkg.dev/yourown-chat/ycs-dev-containers/mattermost:<tag>
```

What the stack creates (all via the `cloudbuild-image` module):

- one Cloud Build **2nd-gen GitHub connection** + repository link to
  `pilprod/mattermost`,
- a dedicated least-privilege **build service account**
  (`ycs-img-build@yourown-chat.iam.gserviceaccount.com`) with only
  `logging.logWriter` (project) and `artifactregistry.writer` (scoped to the two
  target repos),
- two **tag-triggered** builds (prod + dev) that run `docker build -f Dockerfile .`
  and push the tagged image.

Authentication is the same keyless path as the platform stack (HCP OIDC -> WIF
-> apply-SA impersonation). No static credentials or SA keys are used.

---

## 0. Prerequisites

- The **platform stack is applied first**. It enables the Cloud Build and
  Artifact Registry APIs and creates the per-environment repositories
  `ycs-prod-containers` and `ycs-dev-containers`. The build stack references
  those repos by name and never creates them (loose coupling, single owner).
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

## 3. Grant the apply SA the extra roles this stack needs

The platform stack's apply SA (`terraform-apply@yourown-chat.iam.gserviceaccount.com`)
manages the build resources. Grant the additional least-privilege roles:

```bash
export PROJECT_ID="yourown-chat"
export APPLY_SA="terraform-apply@yourown-chat.iam.gserviceaccount.com"

for ROLE in \
  roles/cloudbuild.connectionAdmin \
  roles/cloudbuild.builds.editor \
  roles/iam.serviceAccountAdmin \
  roles/secretmanager.admin \
  roles/artifactregistry.admin ; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${APPLY_SA}" --role="$ROLE" --condition=None
done
```

Why each role:

- `cloudbuild.connectionAdmin` — create the 2nd-gen connection + repository.
- `cloudbuild.builds.editor` — create the triggers.
- `iam.serviceAccountAdmin` — create the build SA and grant `actAs` on it (the
  apply SA needs `serviceAccountUser` on the build SA to create triggers that
  run as it; the module adds that binding).
- `secretmanager.admin` — grant the Cloud Build agent accessor on the PAT secret.
- `artifactregistry.admin` — grant the build SA `writer` on the target repos.

## 4. Fill the deployment inputs

In `stacks/build/deployments.tfdeploy.hcl`, the `build` deployment is already
wired for `yourown-chat`. Set the one real value from step 2:

- `github_app_installation_id` -> the installation ID (**numeric**; replace the
  `0` sentinel in the `build` deployment). A `> 0` validation blocks the plan
  until it is set.
- `github_pat_secret_id` -> `github-pat` (default; change only if you named it
  differently).

The `builds` map already routes the two tag patterns to `ycs-prod-containers`
and `ycs-dev-containers` in `europe-west3`.

## 5. Create the Stack in HCP Terraform

1. Create a **second** HCP Stack (e.g. `yourown-chat-eu-build`) with its
   **working directory set to `stacks/build`**, connected to this repo.
2. Reuse the same WIF pool/provider and apply SA (keyless auth is identical).
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
  europe-west3-docker.pkg.dev/yourown-chat/ycs-prod-containers/mattermost \
  --project=yourown-chat
```

## 7. Reference the image in the workloads

Already wired in the manifests (change the tag to the one you pushed):

- **prod** `platform/mattermost/mattermost.yaml`:
  `spec.image: europe-west3-docker.pkg.dev/yourown-chat/ycs-prod-containers/mattermost`,
  `spec.version: v9.11.3-patched` (the operator builds `image:version`).
- **dev** `platform/dev/mattermost-dev.yaml`:
  `image: europe-west3-docker.pkg.dev/yourown-chat/ycs-dev-containers/mattermost:v9.11.3-patched-dev`.

## Notes

- **Tag patterns are disjoint.** `^v.*-patched$` matches `v9.11.3-patched` only
  (ends with `-patched`); `^v.*patched-dev$` matches `v9.11.3-patched-dev` only
  (ends with `patched-dev`). A dev tag never fires the prod build and vice versa.
- **No AR repo creation here.** Apply the platform stack first; the build stack
  only grants its SA writer on the existing repos.
- **Rotating the PAT** is a `gcloud secrets versions add github-pat` away; the
  connection reads `versions/latest`.
