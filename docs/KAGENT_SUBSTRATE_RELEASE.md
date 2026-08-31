# kagent/Substrate testbed activation

This rail is a production-ineligible external-local-provider testbed. It keeps
the existing Terraform-managed `kagent` Helm release live while prerequisites
are prepared, then gives Cloud Deploy ownership only through a later reviewed
handoff. Do not combine the two ownership phases in one HCP Terraform run.

## Immutable Substrate semver handoff

The reviewed public `pilprod/substrate` `v0.0.22` release is recorded in
`helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json`
with an adjacent SHA-256 checksum. Its source commit is
`e9ed68e587b56df2aa2a7f0267a744598c4d48b4`; application and CRD charts plus
all release images and the agentgateway dependency are digest-qualified. This
is app-gcp consumer evidence, not a producer release asset, because that semver
workflow published OCI artifacts without `substrate-gke-preview.json`.

Validate and render only the Substrate portion with:

```sh
terraform/app-gcp/scripts/render-substrate-semver-consumer-pin-fragment.py \
  helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json
```

The output is intentionally incomplete. Do not set `bootstrap_enabled` or
`release_enabled` from this record: independent kagent evidence, compatibility
attestations, native Secret synchronization, ownership handoff and Broker smoke
gates remain separate reviewed inputs.

## Phase A: apply before any ownership forget

Phase A renames the Terraform address from
`helm_release.application` to `helm_release.application_handoff_source` with a
Terraform `moved` block. The Helm resource attributes are unchanged,
`vendor_chart_bundles.kagent.application_enabled` remains `true`, and
`kagent_substrate_delivery.release_enabled` remains `false`.

The first app-gcp HCP run for this commit must show only the address move for
the existing kagent application release: no Helm update, replacement, delete or
uninstall. Apply that run and verify `helm status kagent -n kagent-system`
before preparing Phase B. Phase B (`removed` plus `destroy = false`) is
intentionally absent from this commit and must not be added or applied until
the Phase A state move has completed.

## Native Secret source contract

Terraform creates or references nine Secret Manager containers, but never
reads their bytes. The operator rail synchronizes the following exact sources:

| Logical source | Secret Manager ID | Kubernetes Secret | Exact keys |
| --- | --- | --- | --- |
| `postgres` | `substrate-database-url` | `ate-system/substrate-cloud-sql` | `connection-string` |
| `api_tls` | `substrate-ate-api-tls` | `ate-system/substrate-ate-api-tls` | `server-credential-bundle.pem`, `client-ca.pem` |
| `controller_tls` | `substrate-ate-controller-tls` | `ate-system/substrate-ate-controller-tls` | `client-credential-bundle.pem`, `server-ca.pem` |
| `egress_gateway_tls` | `substrate-atenet-egress-server-tls` | `ate-system/substrate-atenet-egress-server-tls` | `server-credential-bundle.pem`, `server-ca.pem` |
| `egress_authorizer_tls` | `substrate-atenet-egress-client-tls` | `ate-system/substrate-atenet-egress-client-tls` | `client-credential-bundle.pem`, `server-ca.pem` |
| `actor_id_jwt_pool` | `substrate-actor-id-jwt-pool` | `ate-system/actor-id-jwt-pool` | `pool` |
| `actor_id_ca_pool` | `substrate-actor-id-ca-pool` | `ate-system/actor-id-ca-pool` | `pool` |
| `kagent_client_tls` | `kagent-ate-client-tls` | `kagent-system/kagent-ate-client-tls` | `client-credential-bundle.pem`, `server-ca.pem` |
| `kagent_dev_client_tls` | `kagent-dev-ate-client-tls` | `kagent-dev/kagent-dev-ate-client-tls` | `client-credential-bundle.pem`, `server-ca.pem` |

The chart also always mounts `ate-system/actor-id-ca-certs` key `ca.crt`.
There is deliberately no tenth Secret Manager container: the operator derives
that cert-only Secret from `actor_id_ca_pool.pool` at
`CAs[0].RootCertificateDER`, verifies it is currently valid, permits certificate
signing, has `CA:TRUE`, and has a public key matching the pool signing key, then
verifies the applied bytes exactly.

`native_secret_sync_ready` means all nine source Secrets and this derived
tenth Kubernetes Secret are valid. Leave it `false` after any partial or failed
run.

## Owner-only operator bundle for a fresh bootstrap

The fresh-cluster bootstrap requires one local JSON bundle with schema
`yourown.chat/kagent-substrate-native-secret-bundle/v1`. It contains exactly
`schema`, `projectId`, and the nine `secrets` records from the table. The
PostgreSQL record uses `source: "existing-raw"` and carries no data; its current
value is read from `substrate-database-url`. Each of the other eight uses
`source: "operator-envelope-v1"` and an exact `data` map whose values are
canonical base64 of the file bytes. Base64 is encoding, not encryption.

A record has this shape (use the exact IDs, namespace, name and keys from the
table):

```json
{
  "secretManagerId": "substrate-ate-api-tls",
  "namespace": "ate-system",
  "kubernetesName": "substrate-ate-api-tls",
  "source": "operator-envelope-v1",
  "data": {
    "server-credential-bundle.pem": "BASE64_FILE_BYTES",
    "client-ca.pem": "BASE64_FILE_BYTES"
  }
}
```

Create the bundle outside every Git worktree, set mode `0600`, and keep it on
an owner-controlled encrypted volume. The script rejects symlinks, a different
owner, any group/other permission bit, duplicate or additional JSON keys,
wrong IDs, and any bundle path inside any Git worktree or Git metadata
directory. The MVP actor CA pool is root-only and rejects non-empty
`IntermediateCertificatesDER`. Secret bytes are passed
to Google Secret Manager through `--data-file` and to Kubernetes through
server-side apply on stdin; they do not enter HCL, Terraform plans or Terraform
state. The script uses a private temporary directory and deletes it on exit.

## Validate, bootstrap and rotate

Required local commands are Bash, Python 3, `jq`, OpenSSL, ripgrep, the standard
POSIX command-line tools, `gcloud` and `kubectl`; the one-time existing-Secret
adoption below additionally requires Go. The operator needs `get`,
`versions.access` and `versions.add` on the nine fixed Secret Manager
containers, and `get`/`patch` for Secrets only in `ate-system`, `kagent-system`
and `kagent-dev`, plus `create` for the initial materialization. Because the
preflight verifies all three namespaces, the kube identity also needs cluster-scoped
`get` on `namespaces`. Kubernetes access, Secret Manager container presence and
all required reads are checked before any new version is uploaded. Secret
Manager itself enforces `versions.add` on the first stdin upload; that permission
has no non-writing CLI probe, and a denial stops the run before Kubernetes is
mutated.

Validate without external writes:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh validate \
  --project yourown-chat \
  --bundle /secure/kagent-substrate-native-secrets.json
```

After the bootstrap HCP run has created all three namespaces and all containers,
add eight envelope versions and synchronize all ten Kubernetes Secrets:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh bootstrap \
  --project yourown-chat \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b \
  --bundle /secure/kagent-substrate-native-secrets.json
```

### One-time adoption of the current live Secrets

The current cluster already has the complete native Secret set. After the
bootstrap HCP run creates the eight missing empty Secret Manager containers,
adopt that exact prestate without creating an owner bundle:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh adopt-existing \
  --project yourown-chat \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b
```

`adopt-existing` is deliberately narrower than bootstrap or rotation. It accepts
no bundle and no arbitrary namespace, Kubernetes Secret or Secret Manager ID.
It reads only the fixed nine source Secrets and the fixed derived
`ate-system/actor-id-ca-certs`. The current `substrate-database-url` latest
version remains authoritative and must equal the live
`ate-system/substrate-cloud-sql` bytes exactly. Each other Secret Manager target
must be empty, or contain exactly one enabled envelope whose decoded keys and
bytes exactly match the live Kubernetes source. The latter state permits a safe
retry after an interrupted initial upload; any history, disabled version or
mismatch fails closed.

The helper validates the entire PostgreSQL, pool, certificate, trust-chain, EKU,
SAN and derived-CA contract in one Go process before the first external write.
Secret bytes remain only in process memory and child-process pipes: there is no
bundle, temporary payload file, `--out-file`, secret-bearing argument or raw
child diagnostic. Core dumps and gcloud HTTP-body logging are disabled. Missing
envelopes are uploaded with `--data-file=-`, and the exact returned version is
read back into memory and byte-compared before Kubernetes reconciliation starts.

Run the command only inside an **exclusive, quiesced adoption window**. From
the first read until the command returns successfully, stop Secret rotation,
controller reconciliation, manual changes to these ten Kubernetes Secrets and
creation, enablement, disablement or destruction of versions in the nine Secret
Manager containers. Kubernetes and Secret Manager do not provide a shared
transaction. The helper therefore uses fail-closed phase barriers, but it cannot
make a concurrent cross-system writer atomic; an interrupted run may leave only
the already verified, exact Secret Manager versions and/or managed Kubernetes
labels for a safe retry. Do not attest readiness until the command succeeds.

All ten existing Kubernetes Secret UIDs and data are then reconciled with
server-side apply over stdin and read back. Immediately before the first Secret
Manager upload it re-reads all ten sources and requires unchanged identity, UID,
resourceVersion and data. It then revalidates the exact metadata and payload of
all nine Secret Manager sources immediately before Kubernetes reconciliation,
again after the whole-set Kubernetes readback and before cleanup, and once more
before reporting success. Only after the cleanup barrier succeeds does the
helper remove any legacy
`kubectl.kubernetes.io/last-applied-configuration` annotation with a
UID/resourceVersion-guarded metadata patch, then verify both the data and the
annotation absence. A failure before or during Secret Manager upload therefore
does not mutate Kubernetes or remove recovery metadata. The command prints only
Secret names and Secret Manager version resource names. Run this mode only for
the reviewed current prestate; use `bootstrap` for a fresh cluster and `sync`
for later Secret Manager-to-Kubernetes reconciliation.

For later reconciliation from existing Secret Manager versions, no local
bundle is accepted:

```sh
terraform/app-gcp/scripts/bootstrap-kagent-substrate-secrets.sh sync \
  --project yourown-chat \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b
```

Both write modes validate every payload before Kubernetes mutation. Checks
cover PostgreSQL URI shape, closed pool JSON, pool private-key/certificate
matching, credential-bundle order, key/leaf matching, trust chains, TLS EKU,
and these identities:

- server DNS SANs `api.ate-system.svc` and
  `atenet-egress.ate-system.svc`;
- controller URI SAN
  `spiffe://cluster.local/ns/ate-system/sa/ate-controller`;
- atenet URI SAN
  `spiffe://cluster.local/ns/ate-system/sa/atenet-egress`;
- kagent URI SAN
  `spiffe://cluster.local/ns/kagent-system/sa/kagent-controller`;
- kagent dev URI SAN
  `spiffe://cluster.local/ns/kagent-dev/sa/kagent-controller`.

The script prints only Secret names and Secret Manager version resource names.
It never changes `native_secret_sync_ready`; that attestation belongs in a
separate reviewed app-gcp HCP run after the operator evidence is checked.

## Shared Substrate application activation

The bootstrap run deliberately stops at namespace, CRDs, RBAC, policies and
Secret containers. Once the native Secret sync is verified, a later app-gcp
run may set both `native_secret_sync_ready=true` and `release_enabled=true`.
That run, not Cloud Deploy, installs all shared runtime resources in
`ate-system`:

- Terraform applies the hardened `substrate-broker`
  `AgentgatewayParameters` with the platform-published regional address name;
- the digest-qualified `substrate` application chart creates
  `ate-api-server`, the external-template `ate-controller`, `atenet-egress`,
  the one `Gateway` and the one `TLSRoute`; and
- `release_ready` reads the parameters, both Deployments, Gateway and TLSRoute
  back from the Kubernetes API and requires available API/controller replicas.

The app-gcp apply stays fail-closed if only the CRD chart exists. Gateway
`Programmed=True` and external TLS/gRPC reachability are still later rollout
verification gates. kagent dev-to-production promotion reuses this shared
Substrate release and never installs or upgrades it.

`adopt_existing_substrate=true` is a cluster-specific recovery input, not a
generic import-if-present switch. It is valid only for the exact current full
prestate: namespace `ate-system`, ConfigMap
`ate-system/ate-api-authentication`, plus Helm releases
`ate-system/substrate-crds` and `ate-system/substrate`. The current releases
were installed as `substrate-crds-0.1.0-preview.20260830.1` and
`substrate-0.1.0`. If any expected object is absent, its declarative import
fails closed; do not use this input for a fresh cluster or a partial prestate.
Existing Helm-owned RBAC is deliberately not an import target. Bootstrap
creates additive Terraform-owned Roles, RoleBindings, ClusterRoles and
ClusterRoleBindings under stable, non-Helm names for the same service accounts
and with the same permissions.

The additive kagent getter/writer rules are a migration union: they retain the
live `0.9.12` `kagent.dev` permissions for `agents`, `agents/finalizers` and
`agents/status`, and add the `.kap.2` `harnesses` and `agenttemplates` families
without removing the other common resources. The prod controller receives an
explicit migration-only RBAC target for `kagent-testbed`; dev does not. This
bridge grants only the controller getter/writer union: `ate-api-server` receives
no Secrets or ConfigMaps access in the legacy namespace. The bridge must remain
until the old controller Pod no longer runs or watches that namespace, all
legacy agents and workloads have been migrated, and `kagent-testbed` is
drained. Only a separate reviewed retirement change may remove the migration
target, followed by namespace retirement.

The handoff is deliberately staged. Before each adoption apply, confirm the
recorded live inventory and compatibility evidence below still match the
cluster, then explicitly acknowledge that review by setting
`adopt_existing_substrate_compatibility_confirmed=true`. Adoption with bootstrap
enabled fails closed without that explicit attestation.

1. Set `bootstrap_enabled=true`, keep `release_enabled=false`, and set both
   adoption inputs true. Terraform imports the namespace, CRD Helm release,
   and authentication ConfigMap. In the same apply it creates the parallel
   kagent and Substrate RBAC names before either Helm release changes. Review
   the intentional authentication principal migration together with creation
   of `ate-enrollment-admin`, and verify every existing service account has its
   unchanged permissions through the new bindings, including the prod-only
   `kagent-testbed` bridge.
2. Leave both adoption inputs enabled for the later application stage. Set
   `release_enabled=true` only after bootstrap reconciliation and native Secret
   synchronization are complete. Terraform imports `ate-system/substrate`
   before the pinned application plan is applied. The chart's
   `rbac.create=false` upgrade may then prune its old RBAC names; the additive
   Terraform RBAC remains present and is outside the Helm stored manifest.
3. After all four imported objects are present at their Terraform addresses,
   the parallel RBAC is verified and the reviewed application rollout
   succeeds, clear both adoption inputs.

The reviewed compatibility audit found that the live binaries report dirty
commit `aa5e123`, while clean release commit `e9ed68` / `v0.0.22` is its merge
successor: its parents are upstream `0.1.0` commit `0118c301` and
external-provider commit `fbdc766`, and `aa5e123` is an ancestor. The live chart
does not yet render the Gateway that the target release adds. The live-to-target
CRD server diff is description-only. This evidence supports the staged upgrade;
it does not make adoption implicit. The compatibility boolean remains an
explicit per-apply attestation so a later drifted prestate cannot reuse this
review silently.
Application release remains disabled in checked-in inputs. Do not enable it
against an existing Helm release without the staged import: Terraform cannot
create a second release with the same name, and shared Substrate must never be
implicitly reinstalled by kagent promotion.

## Local-provider-only network mode

This MVP intentionally tests external local Codex/Claude providers and does not
test Actor/MCP egress. `kagent_substrate_delivery.local_provider_only=true`
therefore requires an empty `atenet_egress_destinations` map and creates no
external atenet NetworkPolicy route. The default remains `false`: with that
default an enabled bootstrap requires at least one explicit reviewed CIDR and
port, while `0.0.0.0/0` and `::/0` remain forbidden.

## Release-bound production promotion gate

Cloud Deploy first deploys the immutable candidate to `kagent-dev`. The prod
stage uses the same rendered chart and image digest set, requires explicit
approval, and runs `require-external-broker-smoke` as its first PREDEPLOY job.
That action runs in Cloud Build under a dedicated service account. Kubernetes
RBAC lets that identity only `get` the single Terraform-owned ConfigMap
`ate-system/kagent-production-promotion-gate`; it cannot mutate the
attestation or any workload.

After the local Agent Host has completed TLS, SNI and gRPC smoke against the
public Broker for the dev candidate, set both reviewed inputs in one app-gcp
Terraform run:

```hcl
external_broker_smoke_ready   = true
external_broker_smoke_release = "EXACT_CLOUD_DEPLOY_RELEASE_ID"
```

The ConfigMap records those values. PREDEPLOY reads both keys from one
Kubernetes API snapshot, compares the exact release ID to Cloud Deploy's
`CLOUD_DEPLOY_RELEASE` environment variable, and exits non-zero when the
ConfigMap or a key is missing, readiness is not the exact string `true`, or the
attested release differs. Therefore evidence from an older candidate cannot
open a later production rollout. The hook runs after an approval is granted
but before the deploy job; an early approval can create a failed predeploy
attempt, but cannot change the production workload.

For the next candidate, reset readiness to false and the release ID to the
empty string before recording new evidence. This operational attestation does
not alter the rendered Skaffold release, so the already verified immutable
candidate is promoted rather than rebuilt.
Rollback is equally fail-closed: re-attest the exact older Cloud Deploy release
ID after its external compatibility smoke before starting the rollback rollout.

## No-port-forward enrollment rail

The long-lived local Agent Host uses the public Broker without a port-forward.
Initial external-provider enrollment is issued separately with
`terraform/app-gcp/scripts/issue-substrate-external-provider-enrollment.sh`.
That helper verifies the Terraform-managed persistent default-deny policy,
runs either the exact verified Substrate `v0.0.22` native `kubectl-ate` binary
or the legacy digest-pinned image in a restricted in-cluster Pod, talks only to
`api.ate-system.svc:443`, and publishes the single-use credential into an
owner-only local file. The native binary is selected for the explicit Linux
node architecture, checked against immutable GitHub release metadata,
checksums, annotated tag/source identity and pinned extracted-binary digest,
then streamed through `kubectl exec -i` into a memory-backed `emptyDir`. This
requires no GitHub authentication; an existing authenticated modern `gh` CLI
adds signed immutable-release attestation verification without any login or
refresh action. The helper does not pass credential bytes through Terraform
state, a Kubernetes Secret, ConfigMap, Pod logs, command arguments, or a
port-forward.

The enrollment helper is not part of the native Secret bootstrap and does not
change any activation attestation. Run it only after the app-gcp bootstrap
prerequisites and the reviewed immutable transfer image digest exist.
