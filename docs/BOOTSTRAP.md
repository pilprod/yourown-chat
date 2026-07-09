# Bootstrap: keyless GCP auth for HCP Terraform Stacks

One-time setup you run **before** the first Stack apply. It creates the Workload
Identity Federation (WIF) plumbing and the least-privilege service accounts that
HCP Terraform impersonates. Nothing here is stored in git; no service account
keys are ever created.

## Auth flow

```
HCP Terraform run
   -> mints OIDC JWT   (identity_token "gcp", aud = hcp.workload.identity)
   -> WIF provider     (issuer app.terraform.io, verifies org/project/stack)
   -> STS token exchange (audience = full WIF provider resource name)
   -> impersonates a least-privilege SA (plan or apply)
   -> short-lived access token
   -> google provider  (external_credentials) -> Google Cloud APIs
```

The stack side is already wired:

- `stacks/platform/deployments.tfdeploy.hcl` -> `identity_token "gcp"` (its
  `audience` is the full `https://iam.googleapis.com/projects/.../providers/...`
  provider URL) and the `prod` / `dev` deployments each pass `identity_token`,
  `audience`, `service_account_email`.
- `stacks/platform/providers.tfcomponent.hcl` -> `provider "google"` uses `external_credentials`.

You only need to create the cloud-side resources below and fill three
`REPLACE-ME-*` inputs.

## Prerequisites

- A GCP project with billing linked (the platform provisions **into** an
  existing project; it does not create the project/org).
- `gcloud` authenticated as a user allowed to manage IAM + WIF in that project.
- Your HCP Terraform organization and Stacks project names.

```bash
export PROJECT_ID="REPLACE-ME-platform-project"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export POOL_ID="hcp-tf-pool"
export PROVIDER_ID="hcp-tf-provider"
export HCP_ORG="REPLACE-ME-hcp-org"
export HCP_PROJECT="REPLACE-ME-hcp-stacks-project"   # HCP Terraform "project" that owns the Stack
```

## 1. Enable the APIs needed for federation

```bash
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project="$PROJECT_ID"
```

## 2. Create the least-privilege plan + apply service accounts

Two SAs so a `plan` cannot mutate infrastructure. **Owner/Editor are never
used.** The apply roles below are the union of what the stack's modules manage
(project services, IAM/WIF for tenants, network + PSA, GKE, Cloud SQL, Secret
Manager, GCS, Artifact Registry, Cloud Build, Cloud Deploy), scoped to the one
project.

```bash
# Plan: read-only. securityReviewer lets refresh read IAM policies.
gcloud iam service-accounts create ycs-tf-plan \
  --project="$PROJECT_ID" --display-name="HCP Terraform - plan (read-only)"
PLAN_SA="ycs-tf-plan@${PROJECT_ID}.iam.gserviceaccount.com"
for R in roles/viewer roles/iam.securityReviewer; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${PLAN_SA}" --role="$R" --condition=None
done

# Apply: least-privilege admin per managed service.
gcloud iam service-accounts create ycs-tf-apply \
  --project="$PROJECT_ID" --display-name="HCP Terraform - apply"
APPLY_SA="ycs-tf-apply@${PROJECT_ID}.iam.gserviceaccount.com"
for R in \
  roles/serviceusage.serviceUsageAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/compute.networkAdmin \
  roles/compute.securityAdmin \
  roles/servicenetworking.networksAdmin \
  roles/container.admin \
  roles/cloudsql.admin \
  roles/secretmanager.admin \
  roles/storage.admin \
  roles/artifactregistry.admin \
  roles/clouddeploy.admin ; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${APPLY_SA}" --role="$R" --condition=None
done
```

> Tighten further later by swapping project-level roles for resource-scoped IAM
> conditions once names stabilise. Start here to keep the first apply unblocked
> without ever granting Owner/Editor.

## 3. Create the WIF pool + provider (trusts HCP Terraform)

```bash
gcloud iam workload-identity-pools create "$POOL_ID" \
  --project="$PROJECT_ID" --location="global" \
  --display-name="HCP Terraform"

gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location="global" \
  --workload-identity-pool="$POOL_ID" \
  --display-name="HCP Terraform OIDC" \
  --issuer-uri="https://app.terraform.io" \
  --allowed-audiences="hcp.workload.identity" \
  --attribute-mapping="google.subject=assertion.sub,attribute.terraform_operation=assertion.terraform_operation,attribute.terraform_project_name=assertion.terraform_project_name,attribute.terraform_organization_name=assertion.terraform_organization_name" \
  --attribute-condition="assertion.sub.startsWith(\"organization:${HCP_ORG}:project:${HCP_PROJECT}:stack:\")"
```

The `attribute-condition` restricts the pool to tokens minted for **your** HCP
org + Stacks project, so no other tenant can borrow it.

## 4. Allow the federated identity to impersonate each SA (by operation)

Bind `plan` runs to the plan SA and `apply` runs to the apply SA using the
`terraform_operation` attribute. This is the least-privilege split.

```bash
POOL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}"

gcloud iam service-accounts add-iam-policy-binding "$PLAN_SA" \
  --project="$PROJECT_ID" --role="roles/iam.workloadIdentityUser" \
  --member="${POOL}/attribute.terraform_operation/plan"

gcloud iam service-accounts add-iam-policy-binding "$APPLY_SA" \
  --project="$PROJECT_ID" --role="roles/iam.workloadIdentityUser" \
  --member="${POOL}/attribute.terraform_operation/apply"
```

## 5. Fill the deployment inputs

Compute the STS audience (the full provider resource name) and set the
`REPLACE-ME-*` values in the `prod` / `dev` deployments of
`stacks/platform/deployments.tfdeploy.hcl` (they share auth via a `local`):

```bash
echo "audience              = //iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
echo "service_account_email = ${APPLY_SA}"
echo "project_id            = ${PROJECT_ID}"
```

- `audience` -> the `//iam.googleapis.com/...` string above.
- `service_account_email` -> the **apply** SA (`ycs-tf-apply@...`). HCP selects
  plan vs apply per run; the operation-scoped bindings in step 4 ensure a plan
  token can only impersonate the plan SA.

## 6. Create the Stack in HCP Terraform

1. Connect the repo and create a Stack with its **working directory set to
   `stacks/platform`**.
2. HCP reads `*.tfcomponent.hcl` + `deployments.tfdeploy.hcl` and the committed
   `.terraform.lock.hcl`.
3. Plan and apply the `prod` and `dev` deployments. The first plan proves
   federation: if the token is rejected, re-check the `attribute-condition`
   (org/project names) and that the WIF provider's `allowed-audiences` matches
   the `identity_token` block's `audience` (the full
   `https://iam.googleapis.com/projects/.../providers/...` URL).

## Notes

- The **MCP runtime** service account (the third SA in the security brief) is
  created **by the stack** via a Workload Identity component, not here, so it
  stays declarative and least-privilege. See the MCP platform docs.
- Rotating trust = delete/recreate the provider; there are no keys to rotate.
