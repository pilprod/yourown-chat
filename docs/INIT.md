# Google Cloud Initial Setup

One-time, out-of-band bootstrap that both Terraform stacks (`platform` and
`build`) depend on. Run this **once** before applying either stack; afterwards
the two stacks are fully independent and can be applied in **any order**.

This guide:

- enables **all** Google Cloud APIs both stacks need (neither stack manages APIs);
- creates the Workload Identity Pool and OIDC Provider;
- creates service accounts for `plan` and `apply` runs;
- grants impersonation permissions and project IAM roles;
- creates the GitHub personal access token (PAT) secret the build stack reads;
- configures HCP Terraform dynamic provider credentials.

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

## 2. Enable APIs

Both stacks assume every API they use is already enabled here -- neither the
`platform` nor the `build` stack manages `google_project_service` resources (two
stacks cannot both own the same API resource without conflict). Enabling them
once here is what lets the stacks be applied independently.

```sh
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  compute.googleapis.com \
  container.googleapis.com \
  servicenetworking.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  cloudkms.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  clouddeploy.googleapis.com \
  dns.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
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

```sh
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/container.admin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/compute.networkAdmin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountAdmin"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.admin"

# CMEK: create the shared Cloud KMS key ring + HSM key and set encrypterDecrypter
# on it for the Cloud SQL / GCS / Secret Manager service agents (platform stack
# kms component). Scope down to the key ring later if you prefer.
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$APPLY_SA@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudkms.admin"
```

## Resulting Roles

| Service account | Roles |
| --- | --- |
| `terraform-plan@yourown-chat.iam.gserviceaccount.com` | `roles/viewer`, `roles/browser` |
| `terraform-apply@yourown-chat.iam.gserviceaccount.com` | `roles/container.admin`, `roles/compute.networkAdmin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/secretmanager.admin`, `roles/cloudkms.admin` |

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
   SA). Because APIs and the PAT secret are provisioned above, the two stacks are
   independent and can be applied in **any order**. See [`BUILD.md`](BUILD.md).

## Notes

- The **MCP runtime** service account is created **by the stack** via a Workload
  Identity component, not here, so it stays declarative and least-privilege.
- One shared `terraform-apply@` account backs both the `plan` and `apply` phases
  of **both** stacks (the `terraform-plan` SA above is created and impersonable
  too, reserved for a stricter plan/apply split later). The build stack needs a
  few extra roles on `terraform-apply@`; see [`BUILD.md`](BUILD.md).
- Rotating trust = delete/recreate the provider; there are no keys to rotate.
