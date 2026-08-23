# kagent API v2 preview delivery

## Scope

The preview path is deliberately narrower than a production release process:

```text
preview-YYYYMMDD-N tag in pilprod/yourown-chat-kagent
  -> repository-root cloudbuild.preview.yaml
  -> exact locked pilprod/kagent commit
  -> linux/amd64 controller image + SBOM + provenance + blocking scan
  -> immutable image digest
  -> Cloud Deploy kagent-preview
  -> kagent-testbed (verify=true)
```

There is no production target and no branch Cloud Build trigger. A manual
trigger execution fails closed unless `TAG_NAME` matches
`^preview-[0-9]{8}-[1-9][0-9]*$`. A tag in `pilprod/kagent` is source provenance
only and cannot deploy anything.

## Ownership boundary

The disabled `kagent_testbed_enabled` Terraform toggle installs the official
v0.9.12 M0 Helm baseline. It remains `false` and is not the API v2 preview
mechanism. The separate `kagent_preview_enabled=true` input prepares only the
two namespaces, quotas and NetworkPolicies required by Cloud Deploy. It is
explicitly not passed to the Terraform Helm bootstrap module. API v2 candidates
are rendered and owned by Cloud Deploy from `pilprod/yourown-chat-kagent`;
Terraform owns only shared cluster prerequisites plus the pipeline, target,
identities, repository link and trigger. Never enable the M0 Helm release while
the preview pipeline owns the same controller or Helm release name.

## Trigger contract

Terraform passes these substitutions to `cloudbuild.preview.yaml`:

| Substitution | Meaning |
| --- | --- |
| `_PROJECT_ID` | GCP project containing the cluster and registry |
| `_REGION` | Cloud Build, Cloud Deploy and registry region |
| `_ARTIFACT_REPOSITORY` | Artifact Registry repository ID (`docker`) |
| `_DELIVERY_PIPELINE` | Always `kagent-preview` |
| `_INITIAL_TARGET` | Always `kagent-testbed` |
| `_PREVIEW_TAG_REGEX` | Fail-closed preview-tag policy, also enforced inside the build |
| `_PREVIEW_LOCK` | Exact fork candidate lock (`locks/kagent-preview.lock.json`) |
| `_CRDS_READY` | `false` until the one-time current CRD bootstrap is verified |
| `_CRD_BUNDLE_SHA256` | Exact digest of the platform-admin-applied CRD bundle |
| `_SUBSTRATE_READY` | `false` until the irreversible GKE/runtime prerequisite is verified |
| `_SUBSTRATE_VERSION` | Expected external Substrate version (`0.0.20`) |
| `_EVIDENCE_BUCKET` | Dedicated release source/evidence bucket (`yourown-chat-kagent-preview-europe-west3`) |

Cloud Build also supplies the immutable tag event's built-ins, including
`COMMIT_SHA`, `SHORT_SHA`, `TAG_NAME` and `BUILD_ID`.

## Least privilege

The dedicated `kagent-preview-build` service account can:

- write images only to the existing shared Artifact Registry repository;
- write Cloud Logging entries (the repository-owned build runs its scanner in
  the build and needs no project-wide scanning role);
- create releases only in `kagent-preview`;
- act as only the `kagent-preview` execution identity;
- read/write only the short-lived Cloud Deploy source/evidence bucket (there is
  no project-wide Storage role).

The Cloud Deploy execution identity is created by the existing `clouddeploy`
module. Unlike the other delivery families, it does not receive
`roles/container.developer`, because that predefined role can create, update
and delete CRDs. It gets read-only `roles/container.clusterViewer` plus
Terraform-owned Kubernetes Roles that enumerate the current preview render's
namespaced ConfigMaps, Secrets, ServiceAccounts, Services, PVCs, Deployments,
Jobs and `ModelConfig`. The single-stage pipeline makes promotion to production
structurally impossible. Its explicit release-source binding is scoped to the
dedicated preview bucket, and its image read is scoped to the one Artifact
Registry repository; no additional project-wide Storage or Artifact Registry
role is granted. One residual limitation is explicit: Google's required project-level
`roles/clouddeploy.jobRunner` itself contains `storage.objects` create/get/list.
Eliminating that transitive breadth requires a separately qualified conditioned
or custom execution-role/artifact-storage design beyond this preview MVP.

Terraform also owns the locked controller getter/writer Roles and RoleBindings,
plus the narrow `ate-api` environment-source bindings, in both namespaces. The
product assembly excludes those chart templates, so the preview execution GSA
does not need Role/RoleBinding write, `bind` or `escalate`. The preview render
keeps metrics cluster RBAC disabled and the controller at one replica; the
product pipeline rejects every rendered RBAC object, CRD or other unexpected
cluster-scoped resource.

## Preview UI boundary

The product release builds, scans and freezes the UI from the same locked
upstream commit as the controller. It renders one `kagent-preview-ui` replica
behind a `ClusterIP` Service on port 8080. An Ingress, Gateway, HTTPRoute,
NodePort and LoadBalancer are all forbidden by the product render gate.

External browser access is a separate platform-owned, fail-closed step. The
`kagent_preview_ui_access_enabled` input in the `cloudflare` stack defaults to
`false`. A reviewed flip creates only:

- `kagent-preview.yourown.chat` as a DNS record and remotely managed Tunnel
  ingress whose fixed origin is
  `http://kagent-preview-ui.kagent-system.svc.cluster.local:8080`;
- a self-hosted Cloudflare Access application using the existing
  `zero_trust_allowed_emails` identity policy; and
- a published readiness signal consumed by `app-gcp`.

Only after that Cloudflare apply publishes readiness does `app-gcp` create two
additive NetworkPolicies: the existing `mcp-tunnel` cloudflared pod may egress
to UI pods on TCP 8080, and those UI pods accept ingress from that connector.
The controller REST and A2A Gateway Services are not Tunnel origins and receive
no cloudflared NetworkPolicy exception. With the gate off, the UI is still safe
to deploy for qualification because the namespace default-deny admits no
external caller to it.

Cloud Deploy verification is the only intended in-cluster UI exception. The
product locks the Job label
`platform.yourown.chat/verify=kagent-preview`; Terraform admits that selector to
UI:8080 and applies an egress policy that limits the verifier to cluster DNS,
controller:8083 and UI:8080. Kubernetes labels are selectors rather than a
cryptographic workload identity, so the immutable render gate is part of this
control; the exception is not an external authentication path.

The existing connector is reused rather than creating a second tunnel. Its
image is supplied to Cloud Deploy as the immutable `mcp_tunnel_image` digest;
its run token is stored in the CMEK-encrypted `mcp-tunnel-token` Secret Manager
secret and mounted read-only through the GKE Secret Manager CSI driver. The
Cloudflare zone and account are already derived by the edge stack, and the
existing Access email allow-list supplies the identity input. Keep the UI gate
false until the configured Access IdP/login flow and allow-list have been
reviewed; no new account, zone or Kubernetes secret input is needed.

## Activation gate

Terraform configuration alone does not deploy a workload. Before creating the
first `preview-YYYYMMDD-N` tag, verify the documented GKE beta-API/Substrate
prerequisite and the product repository preflight. Enabling the GKE beta APIs
is a separate, reviewed platform action; this delivery change does not perform
it.

The live cluster has no compatible current-main kagent CRDs. The product
repository freezes their exact bootstrap bundle and digest using the pinned
Helm 3.19.0 renderer; Helm 4 output is not canonical for this release. A
platform admin applies and verifies that bundle once, then changes
`kagent_preview_crds_ready` from `false` to `true` together with the exact
`kagent_preview_crd_bundle_sha256` already pinned to
`b34b1165e642e5c621443550f8b212957f49ed9df77e36b87832ee7df51fe1f7`.
`cloudbuild.preview.yaml` fails before release creation while this gate is
false or the digest differs. Cloud Deploy
receives no permission to create or update CRDs, ClusterRoles or
ClusterRoleBindings.

Current `controller-v2` also dials `ate-api` during startup. A second independent
gate, `kagent_preview_substrate_ready`, remains `false` until a platform admin
has enabled the required one-way GKE beta APIs, rolled the affected nodes,
installed external Substrate `0.0.20`, created the reviewed WorkerPool and
verified their health. The build validates `_SUBSTRATE_VERSION` against the
locked runtime contract and creates no release while `_SUBSTRATE_READY=false`.

Validate the wiring without changing GCP or the cluster:

```bash
terraform fmt -check -recursive terraform/app-gcp
terraform stacks -chdir=terraform/app-gcp validate
bash terraform/app-gcp/test/kagent-preview-release.test.sh
bash helm/test/kagent-release.test.sh
```
