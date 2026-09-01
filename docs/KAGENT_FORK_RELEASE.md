# kagent fork preview publication

The complete release control plane for the kagent fork is owned by
`terraform/app-gcp`. `terraform/platform-gcp` owns a private disposable staging
repository, a separate private immutable release repository and the Google APIs
they require. The fork repository is read-only source material; GitHub Actions
is not part of this release path.

`app-gcp` provisions:

- an IAM-protected Pub/Sub topic and source-less `kagent-preview-release`
  trigger that clones `pilprod/kagent` over read-only HTTPS;
- the dedicated `kagent-preview-publisher` service account;
- repository-scoped Artifact Registry write permission;
- On-Demand Scanning permission;
- a private, versioned GCS evidence bucket with a one-year retention policy.

Candidate images are pushed only to the private staging repository and scanned
there. Passing digests are promoted into the private immutable release repository;
a failed security scan therefore exposes no untrusted candidate to deploy consumers.
Artifact Registry rejects any attempt to move an existing final version tag.
The publisher additionally acquires a generation-zero GCS release lock before
the first final reference is written, so concurrent builds cannot assemble a
mixed release. A failed build after locking permanently burns that version and
the next attempt must use a new reviewed tag.

The trigger accepts only the configured `gcp-v...kap.N` preview tag family and requires the
tag's peeled commit to equal the exact reviewed `source_commit` in
`service-inputs.tfdeploy.hcl`. It also requires an annotated tag, verifies that
the commit belongs to the fork's `yourown-chat` branch, and checks that every
final registry tag is absent before and immediately before publication.

For each accepted release it builds multi-platform (`linux/amd64` and
`linux/arm64`) images with BuildKit provenance and SBOM attestations:

- `kagent/controller`;
- `kagent/ui`;
- `kagent/golang-adk`;
- `kagent/codex-harness`.

The publisher deliberately uses Cloud Build's standard regional default-pool
machine instead of requesting an 8- or 32-vCPU high-CPU worker. A project can
have less than eight E2 CPUs of default-pool quota in a region; selecting either
high-CPU size would then reject the build before source verification begins.
The build keeps a two-hour timeout and 200 GiB disk as its explicit capacity
bounds.

It also deterministically packages and publishes `kagent` and `kagent-crds`
under the same Artifact Registry prefix. No `latest` reference is published.
The BuildKit daemon image is digest-pinned and recorded in the receipt. Each
candidate index is resolved into its exact `linux/amd64` and `linux/arm64`
child manifests; both child digests are scanned before any final image or chart
reference is published. A High or Critical result on either platform fails the
build.

The build writes a build-ID-specific, write-once receipt below:

```text
gs://yourown-chat-kagent-preview-evidence-europe-west3/kagent/<version>/<build-id>/
```

The receipt contains schema-3 `release-evidence.json`, its checksum, both chart
archives, scan results and a schema-2 Cloud Build identity receipt. The release
evidence keeps the canonical `v<version>` artifact tag, while the identity
receipt records the reviewed `gcp-v<version>` source tag separately. The deployment input
must copy only the immutable digest references and the verified manifest hash
from this receipt. Cloud Deploy renders one `kagent-substrate` release with a
`kagent-dev` stage and an approval-gated `kagent-prod` stage. Both stages consume
the same digest set; promotion never rebuilds the fork.

The release namespace is deliberately `gcp-v...`, not `v...`. The two public
GitHub release workflows are disabled at repository level and their current
fork definitions fail closed; the private source verifier checks that external
state again before it builds. Publish the annotated tag to the dedicated topic
using Google IAM; no Cloud Build GitHub connection authorization or shared
webhook secret is involved. Submitters receive only `pubsub.publisher` on that
single topic.

After Terraform has applied and an annotated source tag exists at the reviewed
commit, submit it without GitHub or Secret Manager credentials:

```bash
terraform/app-gcp/modules/kagent-preview-publisher/scripts/publish-release-request.sh \
  gcp-v0.0.0-external-slot.kap.4
```

The script uses the existing Google CLI OAuth session only. Build status and
logs are then inspected through the Google Cloud MCP tools.

The legacy empty `kagent-ghcr-write` Secret Manager container is temporarily
retained to avoid an unrelated destructive Terraform migration. The Cloud Build
trigger has no `available_secrets` block and never reads this container. No
GitHub package token or local `gh` session is required.

The repositories intentionally remain private while the Google Cloud project
enforces Domain Restricted Sharing. GKE pulls with its workload identity. A
local Agent Host must authenticate to Artifact Registry before pulling; public
distribution can be added later without changing the build-and-scan gate.
