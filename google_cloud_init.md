# Google Cloud Initial Setup

Initial setup guide for connecting a Google Cloud project to HCP Terraform:

- enable the required Google Cloud APIs;
- create the Workload Identity Pool and OIDC Provider;
- create service accounts for `plan` and `apply` runs;
- grant impersonation permissions and project IAM roles;
- configure HCP Terraform dynamic provider credentials.

## Input Values

| Variable | Value |
| --- | --- |
| `PROJECT_ID` | `yourown-chat` |
| `TFC_ORG` | `papou-work` |
| `TFC_PROJECT` | `yourown-chat` |
| `TFC_STACK` | `yourown-chat-eu-prod` |
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
export TFC_STACK="yourown-chat-eu-prod"

export WIF_POOL_ID="hcp-terraform"
export WIF_PROVIDER_ID="hcp-terraform"

export PLAN_SA="terraform-plan"
export APPLY_SA="terraform-apply"
```

## 2. Enable APIs

```sh
gcloud services enable \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  sts.googleapis.com \
  compute.googleapis.com \
  container.googleapis.com \
  secretmanager.googleapis.com \
  cloudkms.googleapis.com \
  artifactregistry.googleapis.com \
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
  --attribute-condition="assertion.terraform_organization_name=='papou-work'"
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
```

## Resulting Roles

| Service account | Roles |
| --- | --- |
| `terraform-plan@yourown-chat.iam.gserviceaccount.com` | `roles/viewer`, `roles/browser` |
| `terraform-apply@yourown-chat.iam.gserviceaccount.com` | `roles/container.admin`, `roles/compute.networkAdmin`, `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser`, `roles/secretmanager.admin` |

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
