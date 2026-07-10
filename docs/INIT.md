# Google Cloud Initial Setup

One-time, out-of-band bootstrap that both Terraform stacks (`platform` and
`build`) depend on. Run this **once** before applying either stack; afterwards
the two stacks are fully independent and can be applied in **any order**.

This guide:

- enables the **bootstrap** Google Cloud APIs (auth + Service Usage + Secret
  Manager) so Terraform can then enable the rest itself;
- creates the Workload Identity Pool and OIDC Provider;
- creates service accounts for `plan` and `apply` runs;
- grants impersonation permissions and all project IAM roles both stacks need;
- creates the GitHub personal access token (PAT) secret the build stack reads;
- configures HCP Terraform dynamic provider credentials.

Everything a stack can provision itself (all other APIs, every cloud resource)
is left to Terraform -- this doc is the single place for the manual, pre-Terraform
prerequisites.

## Auth flow

```
HCP Terraform run
   -> mints OIDC JWT   (identity_token "gcp", aud = full WIF provider URL)
   -> WIF provider     (issuer app.terraform.io, verifies org + project)
   -> STS token exchange (audience = full WIF provider resource name)
   -> impersonates the least-privilege apply SA
   -> short-lived access token
   -> google provider  (external_credentials) -> Google Cloud APIs
```

The Terraform side is already wired, so this guide only creates the cloud-side
resources below:

- `terraform/platform/deployments.tfdeploy.hcl` -> `identity_token "gcp"` and the
  single `platform` deployment already pass the real `audience` and
  `service_account_email` (`terraform-apply@`) -- no placeholders to fill.
- `terraform/platform/providers.tfcomponent.hcl` -> `provider "google"` uses
  `external_credentials`.
- The `build` stack authenticates the same way with the same apply SA (see
  [`BUILD.md`](BUILD.md)).

## Input Values

| Variable | Value |
| --- | --- |
| `PROJECT_ID` | `yourown-chat` |
| `TFC_ORG` | `papou-work` |
| `TFC_PROJECT` | `yourown-chat` |
| `WIF_POOL_ID` | `hcp-terraform` |
| `WIF_PROVIDER_ID` | `hcp-terraform` |
| `PLAN_SA` | `terraform-plan` |
| `APPLY_SA` | `terraform-apply` |

## 1. Initialize Environment

```sh
export PROJECT_ID="yourown-chat"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

export TFC_ORG="papou-work"
export TFC_PROJECT="yourown-chat"

export WIF_POOL_ID="hcp-terraform"
export WIF_PROVIDER_ID="hcp-terraform"

export PLAN_SA="terraform-plan"
export APPLY_SA="terraform-apply"
```

## 2. Enable the bootstrap APIs

Enable only the **bootstrap** APIs here -- the ones Terraform needs *before* it
can authenticate and enable anything else, plus Secret Manager so the GitHub PAT
secret (step 8) can be created by hand. Every other API is enabled **by the
stacks themselves**: the `platform` stack's `project_services` component enables
what the platform needs, and the `build` stack enables `cloudbuild` +
`artifactregistry`. There is no overlap, so this list is the single source of
truth for manual API enablement.

```sh
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  serviceusage.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID"
```

Expected result:

```text
Operation "operations/acat.p2-1086706391144-c515dbc5-41f7-440a-9ef0-10508fa565d4" finished successfully.
```

## 3. Create Workload Identity Pool

```sh
gcloud iam workload-identity-pools create "$WIF_POOL_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --display-name="HCP Terraform"
```

Expected result:

```text
Created workload identity pool [hcp-terraform].
```

## 4. Create OIDC Provider for HCP Terraform

```sh
gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER_ID" \
  --project="$PROJECT_ID" \
  --location="global" \
  --workload-identity-pool="$WIF_POOL_ID" \
  --display-name="HCP Terraform OIDC" \
  --issuer-uri="https://app.terraform.io" \
  --allowed-audiences="https://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$WIF_POOL_ID/providers/$WIF_PROVIDER_ID" \
  --attribute-mapping="google.subject=assertion.sub,attribute.terraform_organization_name=assertion.terraform_organization_name,attribute.terraform_project_name=assertion.terraform_project_name,attribute.terraform_stack_name=assertion.terraform_stack_name,attribute.terraform_run_phase=assertion.terraform_run_phase" \
  --attribute-condition="assertion.terraform_organization_name=='papou-work' && assertion.terraform_project_name=='yourown-chat'"
```

Expected result:

```text
Created workload identity pool provider [hcp-terraform].
```

## 5. Create Service Accounts

```sh
gcloud iam service-accounts create "$PLAN_SA" \
  --project="$PROJECT_ID" \
  --display-name="HCP Terraform Plan"

gcloud iam service-accounts create "$APPLY_SA" \
  --project="$PROJECT_ID" \
  --display-name="HCP Terraform Apply"
```

Expected result:

```text
Created service account [terraform-plan].
Created service account [terraform-apply].
```

## 6. Allow HCP Terraform Impersonation

Create the principal set for the HCP Terraform organization:

```sh
export WIF_PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$WIF_POOL_ID/attribute.terraform_organization_name/$TFC_ORG"
```

Grant `roles/iam.workloadIdentityUser` to the `plan` service account:

```sh
gcloud iam service-accounts add-iam-policy-binding \
  "$PLAN_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$WIF_PRINCIPAL_SET"
```

Grant `roles/iam.workloadIdentityUser` to the `apply` service account:

```sh
gcloud iam service-accounts add-iam-policy-binding \
  "$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="$WIF_PRINCIPAL_SET"
```

Expected principal set:

```text
principalSet://iam.googleapis.com/projects/1086706391144/locations/global/workloadIdentityPools/hcp-terraform/attribute.terraform_organization_name/papou-work
```

## 7. Grant Project IAM Roles

### Roles for the plan service account

```sh
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PLAN_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/viewer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$PLAN_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/browser"
```

### Roles for the apply service account

One shared `terraform-apply@` SA backs **both** stacks, so grant it every role
either stack needs here (single source of truth -- BUILD.md does not repeat
these). `serviceUsageAdmin` is what lets each stack enable its own APIs via
Terraform.

```sh
export APPLY="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com"

for ROLE in \
  roles/serviceusage.serviceUsageAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/secretmanager.admin \
  roles/container.admin \
  roles/compute.networkAdmin \
  roles/cloudkms.admin \
  roles/artifactregistry.admin \
  roles/cloudbuild.connectionAdmin \
  roles/cloudbuild.builds.editor ; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$APPLY" --role="$ROLE" --condition=None
done
```

Why each role (P = platform stack, B = build stack, shared = both):

- `serviceusage.serviceUsageAdmin` — shared: each stack enables its own APIs
  (`project_services`).
- `resourcemanager.projectIamAdmin` — shared: project-level IAM bindings (e.g.
  the GKE node SA's `artifactregistry.reader`, the build SA's `logging.logWriter`).
- `iam.serviceAccountAdmin` + `iam.serviceAccountUser` — shared: create the
  per-tenant / build service accounts and `actAs` them.
- `secretmanager.admin` — shared: manage secrets (P) and grant the Cloud Build
  agent `secretAccessor` on the `github-pat` secret (B).
- `container.admin`, `compute.networkAdmin` — P: GKE + VPC/NAT/PSA.
- `cloudkms.admin` — P: create the shared CMEK key ring + HSM key and grant the
  Cloud SQL / GCS / Secret Manager service agents `encrypterDecrypter`.
- `artifactregistry.admin` — B: create the `docker` repo and grant the build SA
  `writer` on it.
- `cloudbuild.connectionAdmin`, `cloudbuild.builds.editor` — B: create the
  2nd-gen connection + repository and the tag triggers.

> Start broad to keep the first apply unblocked without granting Owner/Editor;
> tighten later by swapping project roles for resource-scoped IAM conditions once
> names stabilise.

## Resulting Roles

| Service account | Roles |
| --- | --- |
| `terraform-plan@yourown-chat.iam.gserviceaccount.com` | `roles/viewer`, `roles/browser` |
| `terraform-apply@yourown-chat.iam.gserviceaccount.com` | `roles/serviceusage.serviceUsageAdmin`, `roles/resourcemanager.projectIamAdmin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/secretmanager.admin`, `roles/container.admin`, `roles/compute.networkAdmin`, `roles/cloudkms.admin`, `roles/artifactregistry.admin`, `roles/cloudbuild.connectionAdmin`, `roles/cloudbuild.builds.editor` |

## Verification

Check the Workload Identity bindings:

```sh
gcloud iam service-accounts get-iam-policy \
  "$PLAN_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID"

gcloud iam service-accounts get-iam-policy \
  "$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID"
```

Check the project IAM roles:

```sh
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:terraform-plan OR bindings.members:terraform-apply" \
  --format="table(bindings.role, bindings.members)"
```

## 8. Create the GitHub PAT secret (for the build stack)

The `build` stack wires a Cloud Build 2nd-gen GitHub connection to
`pilprod/mattermost`. That connection needs a GitHub **personal access token**,
which is the only credential created by hand -- the stack never stores the token
in git; it just reads `versions/latest` of the secret created here.

### 8.1 Create the fine-grained PAT on GitHub

Create a **fine-grained** token (GitHub -> Settings -> Developer settings ->
Fine-grained tokens):

- **Resource owner**: `pilprod`
- **Repository access**: *Only select repositories* -> `pilprod/mattermost`
- **Repository permissions**:
  | Permission | Access |
  | --- | --- |
  | Contents | Read-only |
  | Metadata | Read-only |
  | Webhooks | Read and write |
  | Commit statuses | Read and write |
  | Pull requests | Read and write |

Scope the token to the fewest repos/permissions Cloud Build needs. To grant it
more later (e.g. add a repo or a permission), edit the same token on GitHub and
add a new secret version (8.3) -- the connection always reads `versions/latest`.

### 8.2 Store it in Secret Manager

```sh
export GITHUB_PAT_SECRET_ID="github-pat"

# Create the container (Google-managed encryption; automatic replication).
gcloud secrets create "$GITHUB_PAT_SECRET_ID" \
  --project="$PROJECT_ID" \
  --replication-policy="automatic"

# Add the token value as the first version (paste the PAT, then Ctrl-D).
gcloud secrets versions add "$GITHUB_PAT_SECRET_ID" \
  --project="$PROJECT_ID" \
  --data-file=-
```

### 8.3 Rotating / re-scoping the token

```sh
# After regenerating or re-scoping the PAT on GitHub, add a new version:
gcloud secrets versions add "$GITHUB_PAT_SECRET_ID" \
  --project="$PROJECT_ID" \
  --data-file=-
```

The build stack's connection reads `versions/latest`, so a new version takes
effect on the next connection reconcile -- no Terraform change needed.

### 8.4 Authorize the Cloud Build GitHub App (installation ID)

The 2nd-gen connection also needs the numeric **installation ID** of the Google
Cloud Build GitHub App on your org/repo:

1. In the Google Cloud console, open **Cloud Build -> Repositories (2nd gen) ->
   Create host connection** for GitHub, or install the *Google Cloud Build*
   GitHub App on `pilprod` and grant it access to `pilprod/mattermost`.
2. Copy the numeric installation ID from the App installation URL
   (`https://github.com/settings/installations/<INSTALLATION_ID>`).
3. Set it in `terraform/build/deployments.tfdeploy.hcl` as
   `github_app_installation_id` (a `> 0` validation blocks the plan until you
   replace the `0` sentinel).

## 9. Create the Stack in HCP Terraform

1. Connect the repo and create a Stack with its **working directory set to
   `terraform/platform`**.
2. HCP reads the `*.tfcomponent.hcl` files + `deployments.tfdeploy.hcl` and the
   committed `.terraform.lock.hcl`.
3. Plan and apply the single `platform` deployment. The first plan proves
   federation end to end: if the token is rejected, re-check the provider's
   `--attribute-condition` (org + project) and that its `--allowed-audiences`
   matches the `identity_token` block's `audience` (the full
   `https://iam.googleapis.com/.../providers/...` URL).
4. For the container-image CI, create a **second** Stack with working directory
   `terraform/build` (same org + project, so it reuses this WIF provider and apply
   SA). Each stack enables the APIs it owns and this bootstrap already created the
   shared roles + the `github-pat` secret, so the two stacks are independent and
   can be applied in **any order**. See [`BUILD.md`](BUILD.md).

## Notes

- The **MCP runtime** service account is created **by the stack** via a Workload
  Identity component, not here, so it stays declarative and least-privilege.
- One shared `terraform-apply@` account backs both the `plan` and `apply` phases
  of **both** stacks (the `terraform-plan` SA above is created and impersonable
  too, reserved for a stricter plan/apply split later). All of its roles — for
  both stacks — are granted in step 7 above, so BUILD.md does not repeat them.
- Rotating trust = delete/recreate the provider; there are no keys to rotate.
