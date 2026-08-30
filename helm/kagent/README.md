# kagent + Substrate public testbed rail

This directory is a single Cloud Deploy target for fork/issue validation. It
is deliberately `production_eligible=false`; it has no production profile or
promotion stage. Existing coordinates stay stable:

- Helm release `kagent` in `kagent-system`;
- kagent workload namespace `kagent-testbed`;
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

Substrate's application chart owns the one `Gateway` and `TLSRoute` by setting
`externalProviderBroker.gateway.enabled=true`. The only raw resource here is
the application-owned `AgentgatewayParameters`, which adds the GKE static-IP
Service annotations and Restricted-Pod-Security overlays. There is no duplicate
Gateway/TLSRoute owner.

`render-release.py` accepts two separate reviewed artifact manifests. Each
must carry source repository/commit, schema/checksum, digest-qualified app and
CRD charts, and digest-qualified images. Helm overrides use exact image-only
allowlists: structural settings such as RBAC, subcharts, NetworkPolicy, Secret
names and topology cannot bypass the checksummed tracked values. Controller,
UI and agent-runtime tags use `<chart-version>@sha256:<digest>` because the
adopted chart renders tag fields, while the Substrate fork's component digest
fields are validated explicitly. The kagent artifact is restricted to
`https://github.com/pilprod/kagent`; the deployed Substrate source commit must
exactly match kagent's Substrate Go dependency. Both artifacts must prove
`rbac.create=false`; the Substrate artifact must additionally attest that its
Gateway and TLSRoute use `gateway.networking.k8s.io/v1`.

The native Secret gate covers Cloud SQL, ate-api/controller mTLS, atenet egress
server and authorizer mTLS, actor identity pools, and the kagent client bundle.
The authentication ConfigMap preserves the GKE cluster-specific issuer while
using the paired in-cluster discovery/JWKS URLs. Terraform adds exact additive
egress policies for the live Kubernetes Service/endpoints, private Cloud SQL,
kagent-to-ate-api and reviewed Actor/MCP destinations; an empty Actor/MCP
destination set keeps activation closed.

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
false. Remaining prerequisites include publishable immutable fork artifacts
containing the verifier image pin, populated and natively synchronized TLS
material, explicit Actor/MCP destinations, the two-step kagent ownership
handoff, and external Broker smoke evidence. Do not flip the rail until all of
them are reviewed.
