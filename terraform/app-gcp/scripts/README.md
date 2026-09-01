# app-gcp input helpers

`bootstrap-kagent-substrate-secrets.sh` is the fail-closed operator path for
the external-local-provider testbed's native Kubernetes Secrets. It validates
an owner-only bundle outside every Git worktree and Git metadata directory,
writes eight structured Secret Manager versions without exposing bytes in
arguments, reads back each exact version returned by `versions add` rather than
racing `latest`, reads the existing Cloud SQL URI,
and synchronizes the exact nine source Secrets plus the Kubernetes-only
`actor-id-ca-certs/ca.crt` derived from the actor CA pool. It never invokes
Terraform or changes the readiness attestation. See
[`docs/KAGENT_SUBSTRATE_RELEASE.md`](../../../docs/KAGENT_SUBSTRATE_RELEASE.md).

`generate-kagent-substrate-operator-bundle.sh` is the local, no-network path
for a fresh bootstrap bundle. It generates new ECDSA P-256 roots, leaves, JWT
authority and actor CA, assembles only the fixed nine-source JSON contract,
invokes the bootstrap validator, and publishes one owner-only `0600` file with
no-clobber semantics. The explicitly supplied output parent must already be an
owner-controlled `0700` directory outside Git. Private staging is `0700` below
that parent and is removed on every exit. See the release guide for validity
defaults, minimums and the rotation procedure.

The current GKE cluster is not eligible for `adopt-existing`: live discovery
found both kagent client TLS Secrets absent. It must use a freshly generated
operator bundle and `bootstrap` in a quiesced credential-rotation window,
followed by restart or reload of every consumer and API/Broker endpoint
verification before readiness. For a legacy cluster where the entire exact
native Secret set already exists, `adopt-existing` invokes the fixed-contract
Go helper `adopt-kagent-substrate-secrets.go`. That one-time path accepts no
bundle or arbitrary Secret names. It validates the whole live contract in
memory, requires
the existing PostgreSQL Secret Manager value to match, uploads only empty
targets over stdin with empty-or-one-exact retry semantics, reconciles the same
ten Kubernetes Secrets over stdin, and removes legacy last-applied annotations
only after exact whole-set readback and a second nine-source Secret Manager
barrier. It rechecks the original Kubernetes UID, resourceVersion and bytes
immediately before the first possible upload, and performs a final nine-source
barrier before success. Secret payloads are never written to a file, command
argument or diagnostic. Because Kubernetes and Secret Manager have no shared
transaction, run adoption in the exclusive, quiesced window described in the
release guide. Later reconciliation remains the `sync` action and flows from
Secret Manager to Kubernetes.

## Public semver consumer evidence

`render-substrate-semver-consumer-pin-fragment.py` validates the checked-in
consumer record for a public Substrate semver release and writes an incomplete
Substrate-only `kagent_substrate_delivery` fragment to standard output:

```sh
terraform/app-gcp/scripts/render-substrate-semver-consumer-pin-fragment.py \
  helm/kagent/evidence/substrate/v0.0.22/substrate-v0.0.22.consumer-evidence.json \
  > /tmp/substrate-v0.0.22-pins.hcl
```

The adjacent checksum is mandatory. The closed
`yourown.chat/substrate-semver-consumer-evidence/v1` schema records source
commit `e9ed68e587b56df2aa2a7f0267a744598c4d48b4`, every public release image,
both OCI chart manifest digests, and the separately sourced immutable
agentgateway dependency. It explicitly sets `producer_release_asset=false`:
this app-gcp record was created from consumer-side verification because the
`v0.0.22` publisher did not upload a handoff manifest. It must not be renamed
to the old `yourown.chat/substrate-gke-preview/v1` producer schema.

The validator rejects duplicate or additional JSON keys, path/tag drift,
checksum drift, mutable references, mismatched ref/digest/version relationships,
an altered source/owner/visibility claim, and Helm overrides that differ from
the chart-consumed pins. `render-release.py` repeats the byte checksum and exact
artifact-field comparison before Cloud Deploy rendering. The fragment remains
incomplete by design: it contains no kagent evidence, compatibility assertion,
bootstrap flag or readiness gate, and it never edits Terraform input or state.

## Legacy GKE preview producer evidence

`render-substrate-preview-pin-fragment.sh` is a read-only bridge from the
Substrate `substrate-gke-preview.json` release artifact to the immutable fields
of an app-gcp vendor chart bundle. It writes HCL only to standard output and
does not edit `service-inputs.tfdeploy.hcl`, Helm values, or Terraform state.

The helper takes exactly three paths:

```sh
terraform/app-gcp/scripts/render-substrate-preview-pin-fragment.sh \
  /path/to/substrate-gke-preview.json \
  helm/vendor/substrate/crds.values.yaml \
  helm/vendor/substrate/application.values.yaml \
  > /tmp/substrate-preview-pins.hcl
```

The downloaded `substrate-gke-preview.json.sha256` must be beside the manifest.
The helper verifies that producer checksum, the closed
`yourown.chat/substrate-gke-preview/v1` schema, the closed source allowlist
(`pilprod/substrate` only), the
source/image-registry/image-tag relationship, every image
and chart digest/reference/version relationship, and the application values'
exact `image.registry`, `image.digests` and dependency
`images.agentgateway` handoff. The closed manifest and values must include the
chart-consumed `ateapi`, `atecontroller`, and `atenet` images plus the
digest-qualified agentgateway sidecar; missing or mismatched pins are rejected.
JSON and YAML duplicate keys are rejected. Both values files must be alias-free
YAML mappings with unique scalar keys directly below
`helm/vendor/substrate`; their exact byte hashes are emitted in the fragment.
The checksum detects artifact corruption but is bundled with the manifest, so
it is not a signature and does not prove that `source.commit` is reachable from
an approved public ref. Obtain both files from the reviewed release run and
complete that independent provenance gate before changing the active bundle.
The fragment's `image_digests` contains every chart-consumed pin: `ateapi`,
`atecontroller`, `atenet`, and the digest extracted from the full
`images.agentgateway` reference. The separately consumed `ateom-gvisor` digest
remains fully validated and is emitted as a digest-qualified provenance
comment, not misrepresented as a chart value.

The output is deliberately not a complete `vendor_chart_bundles.substrate`
entry. The release manifest cannot determine the reviewed `provisioned`,
`application_enabled`, `candidate_tag`, `product_commit`,
`supported_agent_runtimes`, `namespaces`, `endpoints`, `external_sources`,
`flows`, `kubernetes_api_egress_from`, or `database_bindings` fields. The
manifest's digest-qualified `ateom-gvisor` image also belongs in a separately
reviewed WorkerPool resource; the Substrate chart does not create that
environment resource. The helper reports these omissions on standard error and
never fills them with placeholders or defaults.

## External-provider enrollment without port-forwarding

`issue-substrate-external-provider-enrollment.sh` issues the single-use local
Agent Host enrollment through the in-cluster ate-api service. It creates one
unique restricted enrollment Pod, one policy ConfigMap and one run-scoped allow
NetworkPolicy in the Substrate namespace, then removes them on success or
failure. The legacy image-backed path also uses two sequential restricted
control Pods for the atespace create attempt and mandatory readback; native mode
runs both commands inside the verified transfer Pod. Terraform installs the
persistent
`substrate-enrollment-admin-default-deny` NetworkPolicy during bootstrap; the
script verifies its exact fixed-label, empty ingress/egress contract before it
creates any ephemeral resource. It never creates a Kubernetes Secret for the
credential, opens a port-forward, writes credential bytes to logs, or routes
them through Terraform state. The only allowed Pod egress is exact cluster DNS
peers plus the verified `kube-system/kube-dns` Service ClusterIP `/32` on
TCP/UDP 53, and `app=ate-api-server` on TCP 443. No broad CIDR is admitted.

The tracked Substrate Helm values admit the fixed enrollment Pod labels to the
ate-api NetworkPolicy. The script requires the internal endpoint, TLS SNI and
projected ServiceAccount audience to agree exactly as
`api.<substrate-namespace>.svc[:443]`. In the current release those values are
`api.ate-system.svc:443` and `api.ate-system.svc`. The selected ServiceAccount
must already be listed in `externalProviderEnrollmentAdmins`; app-gcp creates
`ate-system/ate-enrollment-admin` for this purpose.

Immediately before enrollment issuance, the helper attempts
`create atespace <owner>` with the exact validated `--owner-atespace`, then
requires `get atespace <owner>` to succeed through the same pinned in-cluster
`kubectl-ate v0.0.22` path. The create exit is deliberately non-authoritative:
both `ALREADY_EXISTS` and a transport failure after a committed create are
resolved by the exact-name readback. A failed or missing readback stops before
`admin create external-provider-enrollment`; no enrollment credential can be
issued on that path. In legacy image mode, an error while creating either
control Pod triggers one immediate exact-name Pod readback. The helper enters
the bounded status wait only when that Pod object is confirmed; an unconfirmed
create fails closed immediately, while a confirmed object handles the valid
"request committed, response lost" case.

Before running it:

1. choose the pinned native Substrate `v0.0.22` release, provide an owner-only
   copy of its exact Linux archive, or explicitly retain the digest-qualified
   `kubectl-ate` image path;
2. choose the target Linux node architecture (`amd64` or `arm64`) when using a
   native archive;
3. choose a reviewed minimal transfer image which supplies POSIX `sh`, `sleep`,
   `test`, `mkdir`, `chmod`, `cat`, and `sha256sum` and runs as uid/gid 65532;
4. apply the app-gcp bootstrap prerequisites, including the persistent
   enrollment default-deny NetworkPolicy;
5. save the reviewed slot policy in a real, current-user-owned regular file
   with mode `0400` or `0600`, inside a real owner-writable/searchable directory
   owned by the current user with no group/other permissions; and
6. create a real current-user-owned output directory with no group/other
   permissions. The destination file must not exist.

The primary path downloads the exact `linux-<arch>` archive and published
checksums from the immutable public release. It requires no GitHub login. It
fail-closes on any mismatch in the pinned release ID, asset identities and
sizes, GitHub asset digests, checksum file, annotated tag object, signed-tag
presence, or the GitHub-verified source commit. When an already-authenticated
compatible `gh` CLI is available, it additionally verifies GitHub's
cryptographically signed immutable-release attestation; the helper never
invokes `gh auth login` or `gh auth refresh` and the unauthenticated API path
remains complete.

Invoke it with the release and the target node architecture:

```sh
terraform/app-gcp/scripts/issue-substrate-external-provider-enrollment.sh \
  --kubectl-ate-release v0.0.22 \
  --runtime-arch amd64 \
  --transfer-image "${TRANSFER_IMAGE}" \
  --context gke_yourown-chat_europe-west3-b_europe-west3-b \
  --cluster-dns-ip "${CLUSTER_DNS_IP}" \
  --namespace ate-system \
  --service-account ate-enrollment-admin \
  --api-endpoint api.ate-system.svc:443 \
  --server-name api.ate-system.svc \
  --ca-secret substrate-ate-controller-tls \
  --owner-atespace tenant-a \
  --worker-namespace external-workers \
  --worker-pool local-agents \
  --max-slots 2 \
  --policy-file /absolute/private/slot-policy.yaml \
  --ttl 1h \
  --output-file /absolute/private/enrollment-token
```

For an offline/pre-fetched handoff, replace the first two flags with
`--kubectl-ate-archive /absolute/private/kubectl-ate-v0.0.22-linux-amd64.tar.gz`
and keep `--runtime-arch amd64`. The archive and its parent must meet the same
owner-only rules as the policy; the helper hard-links it before validation to
prevent pathname replacement and accepts only the exact built-in release size
and digest. Darwin release assets are not accepted because this executable is
run in a Linux Pod. The older `--kubectl-ate-image IMAGE@sha256:DIGEST` mode
remains available and is mutually exclusive with both native sources.

In native mode the extracted binary is kept `0700` in local owner-only scratch,
then streamed over `kubectl exec -i` stdin into a memory-backed `emptyDir` on a
restricted, digest-pinned transfer Pod. The Pod is pinned with Linux/architecture
node selectors, and its received binary digest is checked again before it can
execute. No binary ConfigMap, `kubectl cp`, port-forward, or broad egress is
used. The in-cluster process writes an atomic `0600` credential into the
memory-backed handoff volume. Only after it succeeds does the local script
stream the credential directly into a same-directory `0600` temporary file and
publish it with a hard link, so a concurrent destination is never overwritten.
The credential file itself remains the sole handoff to the Agent Host. Every
byte must be in `A-Za-z0-9_-`; line terminators and other raw bytes are rejected.
