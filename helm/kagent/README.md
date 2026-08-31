# kagent dev-to-production promotion rail

This directory renders one reviewed immutable kagent candidate into two ordered
Cloud Deploy stages. Dev is deployed and verified first; production requires an
explicit approval and verifies the same digest set again:

- dev Helm release `kagent-dev` in `kagent-dev`, watching `agent-codex-dev`;
- production Helm release `kagent` in `kagent-system`, watching `agent-codex`;
- shared Terraform-owned Substrate in `ate-system`; and
- Broker TLS SNI `api.ate-system.svc`.

Cloud Deploy never rebuilds during promotion. Both profiles are rendered from
the same chart and image digest fields in one release receipt. Substrate,
Gateway and CRDs remain prerequisites and are not reinstalled by either stage.

Terraform owns namespaces, quotas, NetworkPolicy prerequisites, CRD releases,
RBAC, `ate-api-authentication`, Secret Manager containers and the
platform-level official agentgateway installation. The existing kagent
application release remains Terraform-managed while this rail is disabled. A
separate, reviewed handoff must first retain the release in-cluster with
`destroy=false` and remove only its Terraform state ownership. Phase A moved
the live object to `helm_release.application_handoff_source[0]`; Phase B must
target exactly that address in its `removed` block. Cloud Deploy must never
race the handoff-source release. After that handoff, Cloud Deploy owns only the
kagent application releases. Shared Substrate remains Terraform-owned.
Every per-agent namespace has Restricted Pod Security labels, a namespace-wide
ingress/egress default deny, DNS-only baseline egress and the controller RBAC
bindings generated from the same namespace map.

Substrate itself is a two-step app-gcp resource. `bootstrap_enabled` creates
the namespace, CRDs, RBAC and pre-sync policies. After the ten native
Kubernetes Secrets are synchronized, `release_enabled` creates the shared
`substrate` Helm release and `ate-system/substrate-broker`
`AgentgatewayParameters`. The atomic Helm release owns `ate-api-server`, the
external-template `ate-controller`, `atenet-egress`, `Gateway` and `TLSRoute`.
`release_ready` reads those resources back from the API and requires available
API/controller replicas, so CRDs alone cannot open the kagent release rail on
a fresh cluster. Gateway `Programmed=True` remains an explicit Cloud Deploy
verification check. Neither dev nor production promotion reinstalls shared
Substrate.

`adopt_existing_substrate=true` is intentionally specific to the current full
cluster prestate. It expects the `ate-system` namespace,
`ate-api-authentication` ConfigMap, and `substrate-crds` and `substrate` releases
to exist. It is not an import-if-present mode: a missing object makes the
corresponding declarative import fail. Existing Helm-owned RBAC is never
imported. Bootstrap first creates additive Terraform-owned RBAC under stable,
non-Helm names for the same service accounts and with the same permissions.
The kagent rules are the exact migration union of live `0.9.12` `agents`,
`agents/finalizers` and `agents/status` permissions with the `.kap.2`
`harnesses` and `agenttemplates` families. A prod-only migration target keeps
that union bound in `kagent-testbed`; dev has no legacy target.

Do not remove the `kagent-testbed` bridge merely because the new chart is
deployed. Removal requires the old controller Pod to be stopped and no longer
watching the namespace, every legacy agent/workload to be migrated, and the
namespace to be drained. Remove the migration target in a separate reviewed
change before retiring the namespace itself.

Before each adoption apply, confirm the recorded compatibility inventory still
matches the cluster. Then enable bootstrap only with both
`adopt_existing_substrate=true` and
`adopt_existing_substrate_compatibility_confirmed=true`; adoption fails closed
without that explicit attestation. That apply imports the namespace, CRD
release and ConfigMap, and creates the parallel kagent and Substrate RBAC while
the existing application release still renders its old objects. Keep both
adoption inputs enabled for the later application stage. The reviewed audit
traced dirty live commit `aa5e123` to
clean merge-successor `e9ed68` / `v0.0.22` (parents: upstream `0118c301` and
external-provider `fbdc766`), confirmed `aa5e123` is an ancestor, found the
live-to-target CRD server diff description-only, and identified the Gateway as
a target addition absent from the live chart. The boolean remains an explicit
per-apply acknowledgment so this evidence cannot silently authorize a drifted
prestate. After bootstrap and Secret synchronization, `release_enabled=true`
imports the application release before the `rbac.create=false` upgrade. That
upgrade may prune only the old Helm-owned RBAC; the parallel Terraform-owned
objects remain outside the Helm stored manifest. Clear both adoption inputs
only after all four imported addresses are state-owned, the parallel bindings
are verified and the rollout succeeds. The checked-in application release
remains disabled.

Substrate's Terraform-managed application chart owns the one `Gateway` and
`TLSRoute`. There is no duplicate Gateway/TLSRoute owner in either kagent
promotion profile.

`render-release.py` accepts two separate reviewed artifact manifests. Each
must carry source repository/commit, schema/checksum, digest-qualified app and
CRD charts, and digest-qualified images. The kagent artifact must use evidence
schema v3: `image_refs` contains only the chart-installed controller and UI,
while `runtime_images` contains exactly `kagentHarness` and `codexHarness`.
Those runtime references are retained in generated release evidence but do not
create an agent. The agents repository must copy the selected immutable digest
into `Harness.spec.workload.image`; kagent then propagates it into Revision and
Substrate ActorTemplate state. Helm overrides use exact image-only allowlists:
structural settings such as RBAC, subcharts, NetworkPolicy, Secret names and
topology cannot bypass the checksummed tracked values. Controller and UI tags
use `<chart-version>@sha256:<digest>` because the adopted chart renders tag
fields, while the removed legacy `controller.agentImage` knob is rejected. The
Substrate fork's component digest fields are validated explicitly. The kagent
artifact is restricted to `https://github.com/pilprod/kagent`; the deployed
Substrate source commit must exactly match kagent's Substrate Go dependency.
Both artifacts must prove `rbac.create=false`; the Substrate artifact must
additionally attest that its Gateway and TLSRoute use
`gateway.networking.k8s.io/v1`.

Substrate `v0.0.22` is recorded separately at
`evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json`. Its
schema deliberately says `consumer-evidence`: the semver publisher exposed
public OCI artifacts but did not emit the old `substrate-gke-preview.json`
producer asset. The adjacent checksum detects repository drift, and the release
renderer reloads that exact checked-in file and compares every Substrate
artifact field before producing Skaffold. This evidence does not assert kagent
artifacts, compatibility gates, native Secret readiness or ownership handoff
readiness.

The native Secret gate covers Cloud SQL, ate-api/controller mTLS, atenet egress
server and authorizer mTLS, actor identity pools, and the kagent client bundle.
It also requires Kubernetes-only `actor-id-ca-certs/ca.crt`, derived exactly
from `actor-id-ca-pool` `CAs[0].RootCertificateDER`; nine source Secrets alone
are not ready. The owner-only bootstrap/sync procedure is documented in
`docs/KAGENT_SUBSTRATE_RELEASE.md`.
The authentication ConfigMap preserves the GKE cluster-specific issuer while
using the paired in-cluster discovery/JWKS URLs. Terraform adds exact additive
egress policies for the live Kubernetes Service/endpoints, private Cloud SQL,
kagent-to-ate-api and reviewed Actor/MCP destinations. The explicit
`local_provider_only` testbed mode instead requires an empty Actor/MCP
destination set and creates no external atenet route.

The in-cluster verifier image is the immutable `images.releaseVerifier` pin
from the same reviewed Substrate handoff as the control-plane images; it is
never an independent release input. The Job projects fresh Substrate- and
Kubernetes-audience tokens and mounts only the public internal serving CA from
`substrate-ate-controller-tls/server-ca.pem` (mode `0444`, readable by the
image's arbitrary non-root UID). It checks kagent HTTP health, authenticated
internal Substrate access with exact SNI `api.ate-system.svc`, and the
application-owned Gateway/TLSRoute `Programmed` state. It deliberately
does not dial the Gateway's own regional external IP from an `ate-system` pod:
GKE hairpin behavior is not proof of client reachability. Public Broker
TLS/gRPC/SNI validation is a separate Cloud Build or local-host smoke gate and
`external_broker_smoke_ready` remains false until that external path exists and
has evidence. False does not block the first deployment that creates the
Gateway; it keeps `external_broker_smoke_required=true` and
`kagent_local_agent_ready=false` afterward. After the dev candidate passes the
external smoke, a reviewed Terraform run sets both
`external_broker_smoke_ready=true` and `external_broker_smoke_release` to that
exact Cloud Deploy release ID. Terraform writes both values to the narrowly
readable `ate-system/kagent-production-promotion-gate` ConfigMap. The prod
PREDEPLOY action compares the live values with `CLOUD_DEPLOY_RELEASE` and fails
before deployment on a missing, false or stale attestation. The rendered
release is independent of the boolean, so dev and prod still use the same
immutable digest set.

External-provider enrollment is issued separately by
`terraform/app-gcp/scripts/issue-substrate-external-provider-enrollment.sh`.
The helper uses the fixed `substrate-enrollment-admin` Pod label set admitted by
`substrate.values.yaml`; Terraform installs a persistent fixed-label default
deny and the helper verifies it before creating a Pod. It talks only to
`api.ate-system.svc:443` and transfers the one-time credential to an owner-only
local file without a port-forward or a Kubernetes Secret. Its only CIDR egress
is the caller-supplied exact
`kube-system/kube-dns` ClusterIP `/32`, verified against the live Service. It
requires release-supplied digest pins; this repository does not invent a
`kubectl-ate` image digest.

The current service input intentionally keeps every activation attestation
false. Before enabling the rail, record the private Artifact Registry receipt,
prepare separate dev/prod database and Substrate client identities, complete
the Terraform-to-Cloud-Deploy Helm ownership handoff, and deploy the dev stage.
A real external Agent Host TLS/gRPC smoke is required before prod deployment.
Approval remains an explicit human action; even if it is clicked early, the
PREDEPLOY job blocks the production deployment until the release-bound
Terraform attestation exists.
