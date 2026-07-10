# Google Cloud Initial Setup

One-time, out-of-band bootstrap that the Terraform **stack** depends on. Run this
**once** before applying; afterwards the single stack provisions the platform,
the image CI **and** the Cloudflare edge in one apply.

This guide:

- enables the **bootstrap** Google Cloud APIs (auth + Service Usage + Secret
  Manager) so Terraform can then enable the rest itself;
- creates the Workload Identity Pool and OIDC Provider;
- creates service accounts for `plan` and `apply` runs;
- grants impersonation permissions and all project IAM roles the stack needs;
- creates the GitHub personal access token (PAT) secret the image CI reads;
- configures HCP Terraform dynamic provider credentials;
- creates the Cloudflare API token the Cloudflare component reads (the only static
  secret, since Cloudflare has no Workload Identity path).

Everything the stack can provision itself (all other APIs, every cloud resource)
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

- `terraform/deployments.tfdeploy.hcl` -> `identity_token "gcp"` and the single
  `prod-eu` deployment already pass the real `audience` and
  `service_account_email` (`terraform-apply@`) -- no placeholders to fill.
- `terraform/providers.tfcomponent.hcl` -> `provider "google"` uses
  `external_credentials`.

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
secret (step 8) can be created by hand. Every other API is enabled **by the stack
itself**: the `project_services` component enables everything the platform, the
image CI and the rest need (compute, container, sqladmin, cloudkms, storage,
clouddeploy, logging, monitoring, cloudbuild, artifactregistry). This list is the
single source of truth for manual API enablement.

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

The `terraform-apply@` SA backs the whole stack, so grant it every role the stack
needs here (single source of truth). `serviceUsageAdmin` is what lets the stack
enable its own APIs via Terraform.

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

Why each role:

- `serviceusage.serviceUsageAdmin` — the stack enables its own APIs
  (`project_services`).
- `resourcemanager.projectIamAdmin` — project-level IAM bindings (e.g. the GKE
  node SA's `artifactregistry.reader`, the build SA's `logging.logWriter`).
- `iam.serviceAccountAdmin` + `iam.serviceAccountUser` — create the per-tenant /
  build service accounts and `actAs` them.
- `secretmanager.admin` — manage secrets and grant the Cloud Build agent
  `secretAccessor` on the `github-pat` secret.
- `container.admin`, `compute.networkAdmin` — GKE + VPC/NAT/PSA + reserved IP.
- `cloudkms.admin` — create the shared CMEK key ring + HSM key and grant the
  Cloud SQL / GCS / Secret Manager service agents `encrypterDecrypter`.
- `artifactregistry.admin` — create the `docker` repo and grant the build SA
  `writer` on it.
- `cloudbuild.connectionAdmin`, `cloudbuild.builds.editor` — create the 2nd-gen
  connection + repository and the tag triggers.

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

## 8. Create the GitHub PAT secret (for the CI/CD connections)

Two Cloud Build 2nd-gen GitHub connections read this token: `mattermost_image`
(builds the image from `pilprod/mattermost`) and `deploy_release` (cuts a Cloud
Deploy release from `pilprod/yourown-chat` on a semver tag). Both need a GitHub
**personal access token**, which is the only credential created by hand -- the
stack never stores the token in git; it just reads `versions/latest` of the
secret created here. One token, scoped to both repos, backs both connections.

> **Why a PAT and not just the KMS key the Console asks for?** Creating a host
> connection in the Cloud Console runs an interactive OAuth flow — you click
> *Authorize* and Google fetches and stores the *Google Cloud Build* OAuth token
> for you; the KMS key it offers is **optional** and only CMEK-encrypts that
> stored token (it is not a substitute for the credential). We create the
> connection **declaratively in Terraform** instead, where there is no browser
> step, so the provider needs the credential up front: a GitHub PAT in Secret
> Manager (`authorizer_credential.oauth_token_secret_version`). In other words the
> PAT **is** the OAuth token the UI would obtain for you. The Cloud Build GitHub
> App (8.4) is still required in both paths — only the token's origin differs. The
> Console's KMS option maps here to encrypting the `github-pat` secret itself
> (Google-managed by default in 8.2; wrap it in the shared CMEK key if you want).

### 8.1 Create the fine-grained PAT on GitHub

Create a **fine-grained** token (GitHub -> Settings -> Developer settings ->
Fine-grained tokens):

- **Resource owner**: `pilprod`
- **Repository access**: *Only select repositories* -> `pilprod/mattermost`
  **and** `pilprod/yourown-chat`
- **Repository permissions** (same on both repos):
  | Permission | Access |
  | --- | --- |
  | Contents | Read-only |
  | Metadata | Read-only |
  | Webhooks | Read and write |
  | Commit statuses | Read and write |
  | Pull requests | Read and write |

Scope the token to the fewest repos/permissions Cloud Build needs. To grant it
more later (e.g. add a repo or a permission), edit the same token on GitHub and
add a new secret version (8.3) -- the connections always read `versions/latest`.

> **Why both repos?** The token backs two connections: the image build reads
> `pilprod/mattermost` (Mattermost **source**), and the automated release cut
> reads `pilprod/yourown-chat` (this repo, which holds the **Helm charts** under
> `helm/`). The `deploy_release` component makes deployment hands-off: on a semver
> tag (`MAJOR.MINOR.PATCH`) in this repo it runs `gcloud deploy releases create
> --source=helm` for you (see [`helm/cloudbuild.yaml`](../helm/cloudbuild.yaml)
> for the equivalent manual command). Because that connection lives in the stack,
> the PAT — and the Cloud Build GitHub App (8.4) — must cover this repo too.

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

The connections read `versions/latest`, so a new version takes effect on the next
connection reconcile -- no Terraform change needed.

### 8.4 Authorize the Cloud Build GitHub App (installation ID)

The 2nd-gen connections also need the numeric **installation ID** of the Google
Cloud Build GitHub App on your org/repos:

1. In the Google Cloud console, open **Cloud Build -> Repositories (2nd gen) ->
   Create host connection** for GitHub, or install the *Google Cloud Build*
   GitHub App on `pilprod` and grant it access to **both** `pilprod/mattermost`
   and `pilprod/yourown-chat` (one installation backs both connections).
2. Copy the numeric installation ID from the App installation URL
   (`https://github.com/settings/installations/<INSTALLATION_ID>`).
3. Set it in `terraform/deployments.tfdeploy.hcl` as
   `github_app_installation_id` (a `> 0` validation blocks the plan until you
   replace the `0` sentinel).

## 9. Create the Stack in HCP Terraform

1. Connect the repo and create **one** Stack with its **working directory set to
   `terraform/`**.
2. HCP reads the `*.tfcomponent.hcl` files + `deployments.tfdeploy.hcl` and the
   committed `.terraform.lock.hcl` (all five providers).
3. Attach the Cloudflare variable set (step 10) to this Stack.
4. Plan and apply the single `prod-eu` deployment. The first plan proves
   federation end to end: if the token is rejected, re-check the provider's
   `--attribute-condition` (org + project) and that its `--allowed-audiences`
   matches the `identity_token` block's `audience` (the full
   `https://iam.googleapis.com/.../providers/...` URL). The one apply provisions
   the platform, the image CI **and** the Cloudflare edge together.

> Migrating from the old three-stack layout: delete (or repoint) the separate
> `platform` / `build` / `cloudflare` HCP Stacks and use this single Stack with
> working directory `terraform/`. State from a prior split layout is not carried
> over automatically.

## 10. Create the Cloudflare API token (for the Cloudflare component)

The `cloudflare` component manages the `yourown.chat` zone (DNS, edge
TLS/security settings, DNSSEC, WAF rules, Origin CA cert). Cloudflare has no
Workload Identity path, so this is the **only** static secret in the whole setup.
It never touches git or state — it is injected from an HCP variable set as an
ephemeral input.

### 10.1 Create a zone-scoped API token

In the Cloudflare dashboard: **My Profile -> API Tokens -> Create Token ->
Create Custom Token**. Scope it to the `yourown.chat` zone only, with:

| Permission | Access | Needed for |
|------------|--------|-----|
| Zone -> Zone | Read | resolve the zone ID (always) |
| Zone -> DNS | Edit | apex A / www / extra / CAA records **and DNSSEC** (always) |
| Zone -> Zone Settings | Edit | SSL mode, HSTS, min TLS, HTTP/3, etc. (always) |
| Zone -> SSL and Certificates | Edit | issue the Origin CA cert for Full (Strict) — **on by default** (`cloudflare_manage_origin_cert`); also `cloudflare_aop_enabled` |
| Zone -> Zone WAF | Edit | *only if you set `cloudflare_custom_firewall_rules`, `cloudflare_managed_waf_enabled` or `cloudflare_rate_limit_rules`* |

The first four rows are the default configuration (DNS + settings + DNSSEC +
origin cert for Full Strict). Add the last row only when you enable WAF rules.
If you turn `cloudflare_manage_origin_cert` off (using a dashboard-created cert
instead), the SSL and Certificates row is not required.

**Zone Resources:** restrict to `Include -> Specific zone -> yourown.chat`.

**Client IP Address Filtering (recommended):** lock the token to HCP Terraform's
egress ranges so a leaked token is unusable from anywhere else. Fetch the current
ranges and add each CIDR under *Client IP Address Filtering -> Is in*:

```bash
# HCP Terraform publishes its egress ranges; the outbound API/run traffic uses
# the "api" list. Re-check on changes (rare).
curl -s https://app.terraform.io/api/meta/ip-ranges | jq -r '.api[]'
```

**TTL (recommended):** set a **TTL / expiry** (e.g. 90 days) and rotate — see 10.3.

Copy the token value once (it is not shown again).

### 10.2 Store it in an HCP variable set

1. In HCP Terraform, create a **variable set** and apply it to the Stack.
2. Add a **Terraform variable** (category *Terraform*, matching
   `category = "terraform"` in the `store "varset"` block) named
   `cloudflare_api_token` = the token. Tick **Sensitive**; leave **HCL
   unchecked** — the token is a plain string, not an HCL expression (HCL is only
   for list/map/object values).
3. In `terraform/deployments.tfdeploy.hcl`, set the `store "varset"` block's `id`
   to that variable set's ID. The token flows in as the ephemeral
   `cloudflare_api_token` input.

> No manual IP hand-off: the proxied apex A record is wired **live** to the
> reserved ingress IP inside the stack (`component.network.ingress_ip_address`),
> so there is nothing to copy between runs.

### 10.3 Rotating / re-scoping the token

Cloudflare API tokens can be rolled without downtime:

1. **My Profile -> API Tokens ->** the token **-> Roll** (new value, same scope),
   or create a new custom token if you need to widen/narrow permissions.
2. Update the `cloudflare_api_token` value in the HCP variable set (10.2).
3. The next plan/apply picks it up — nothing in git or state changes.

If you set a TTL, roll before expiry. If you added IP filtering, re-check the
HCP egress ranges when Cloudflare/HCP announce changes (rare).

### 10.4 Origin TLS secrets (handled during ingress setup)

With `cloudflare_manage_origin_cert = true` (default) the stack issues the Origin
CA cert and fills the `mattermost-origin-tls-cert` / `-key` secrets
automatically — **nothing to do here.** Authenticated Origin Pulls are **off by
default**; when you enable them the stack uploads the per-hostname client cert and
turns AOP on for you, so the only manual secret is the verification CA
(`cloudflare-origin-pull-ca`, the CA that signed that client cert). All of this is
covered where the ingress is set up — see
[`helm/ingress-nginx/README.md`](../helm/ingress-nginx/README.md) §3–4.

## Notes

- The **MCP runtime** service account is created **by the stack** via a Workload
  Identity component, not here, so it stays declarative and least-privilege.
- One `terraform-apply@` account backs both the `plan` and `apply` phases of the
  stack (the `terraform-plan` SA above is created and impersonable too, reserved
  for a stricter plan/apply split later). All of its roles are granted in step 7.
- Rotating trust = delete/recreate the provider; there are no keys to rotate.
