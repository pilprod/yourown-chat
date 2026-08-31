# kagent + Substrate public testbed rail

This directory is a single Cloud Deploy target for fork/issue validation. It
is deliberately `production_eligible=false`; it has no production profile or
promotion stage. Existing coordinates stay stable:

- Helm release `kagent` in `kagent-system`;
- declarative per-agent workload namespaces, initially `codex` ->
  `agent-codex`;
- Helm release `substrate` in `ate-system`; and
- Broker TLS SNI `api.ate-system.svc`.

Terraform owns namespaces, quotas, NetworkPolicy prerequisites, CRD releases,
RBAC, `ate-api-authentication`, Secret Manager containers and the
platform-level official agentgateway installation. The existing kagent
application release remains Terraform-managed while this rail is disabled. A
separate, reviewed handoff must first retain the release in-cluster with
`destroy=false` and remove only its Terraform state ownership. Phase A moved
the live object to `helm_release.application_handoff_source[0]`; Phase B must
target exactly that address in its `removed` block. Cloud Deploy must never
race the handoff-source release. After that handoff,
Cloud Deploy owns only the kagent and Substrate application Helm releases.
Every per-agent namespace has Restricted Pod Security labels, a namespace-wide
ingress/egress default deny, DNS-only baseline egress and the controller RBAC
bindings generated from the same namespace map.

Substrate's application chart owns the one `Gateway` and `TLSRoute` by setting
`externalProviderBroker.gateway.enabled=true`. The only raw resource here is
the application-owned `AgentgatewayParameters`, which adds the GKE static-IP
Service annotations and Restricted-Pod-Security overlays. There is no duplicate
Gateway/TLSRoute owner.

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
from `actor-id-ca-pool` `CAs[0].RootCertificateDER`; eight source Secrets alone
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
`kagent_local_agent_ready=false` afterward. The boolean is an explicit
attestation input, not an automated smoke implementation.

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

The current service input intentionally sets every activation attestation to
false. The immutable Substrate `v0.0.22` consumer record includes the verifier
pin, but independent immutable kagent evidence is still absent. Remaining
prerequisites also include populated and natively synchronized TLS material,
the explicit local-provider-only network posture, the two-step kagent ownership
handoff, and external Broker smoke evidence. Do not flip the rail until all of
them are reviewed.
