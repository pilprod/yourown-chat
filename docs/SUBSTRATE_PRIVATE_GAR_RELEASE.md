# Private Substrate release handoff

Substrate deployment artifacts stay private. GitHub is read-only source and the
public, digest-qualified `v0.0.22` release is only the input to a Google Cloud
handoff. The app-gcp publisher is fail-closed to the Helm profile
`external-control-plane-only`. It copies the four image indexes rendered by
that profile plus the read-only deployment verifier required by Cloud Deploy,
reproduces the two charts from the reviewed source tree, scans both runnable
architectures and publishes passing artifacts into the existing private Google
Artifact Registry:

- `agentgateway`;
- `ateapi`;
- `atecontroller`;
- `atenet`;
- `substrate-release-verify` (evidence key `releaseVerifier`).

The `atelet`, `ateom-gvisor`, `ateom-microvm`, `podcertcontroller` and
other runtime images remain outside this profile. The verifier does not join
the Substrate runtime; it is retained solely as the digest-qualified image used
by the kagent dev/prod verification jobs.

The applied input authorizes exactly this replacement handoff:

```text
source tag:      v0.0.22
tag object:      00a6a684cea3b3feea67461cf79347332ec759ef
source commit:   e9ed68e587b56df2aa2a7f0267a744598c4d48b4
release version: 0.0.22-private.3
release prefix:  europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate
staging prefix:  europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/substrate
```

The publisher does not create a second evidence bucket. It depends on and
reuses the private, versioned kagent evidence bucket, with Substrate receipts
isolated below `substrate/<release-version>/`.

The release evidence declares the exact top-level scope:

```json
{
  "supported_profiles": ["external-control-plane-only"],
  "schema_version": "yourown.chat/substrate-private-gar-release/v2",
  "required_components": ["agentgateway", "ateapi", "atecontroller", "atenet"],
  "auxiliary_components": ["releaseVerifier"]
}
```

Both `images` and `platform_image_digests` contain the union of the runtime and
auxiliary sets. Any broader or narrower set is rejected by the producer guard.
The Terraform consumer branch for schema v2 intentionally remains closed in
this change; a follow-up must pin the successful `.private.3` evidence checksum,
chart digests and all five image digests before bootstrap or release can use it.

## Release sequence

1. Apply the app-gcp configuration that materializes the dedicated service
   account, repository-scoped writers, scanner grant and IAM-protected Pub/Sub
   trigger.
2. Submit the one authorized coordinate:

   ```bash
   terraform/app-gcp/modules/substrate-preview-publisher/scripts/publish-release-request.sh \
     0.0.22-private.3
   ```

3. Follow the Cloud Build through Google Cloud MCP. Do not open kagent bootstrap
   or delivery gates until the build succeeds and the receipt checksum is
   verified.
4. Copy only digest-qualified image and OCI chart references from:

   ```text
   gs://yourown-chat-kagent-preview-evidence-europe-west3/substrate/0.0.22-private.3/
   ```

5. Copy the build's exact generation-qualified `evidence_uri` into
   a separate successor-kagent/app-gcp change. That change must update the
   reviewed kagent source commit, the publisher URI validation and its
   release-scoped GCS IAM prefix together with
   `kagent_preview_publisher.substrate_release_evidence_uri`; the currently
   applied `.kap.3` publisher intentionally still accepts only `.private.2`.
   Apply that complete pin update, and only then submit the successor kagent
   release. Its build identity reads the private object and obtains a
   short-lived Artifact Registry token; the verifier receives those values only
   as ephemeral files inside Cloud Build. An empty URI makes kagent publication
   fail closed.

The build stages the five exact source indexes into the disposable private
repository, verifies both `linux/amd64` and `linux/arm64` manifests and blocks
High or Critical findings for every required component. It then acquires a
generation-zero release lock before writing final references. It publishes no
`latest` tag. A failure after lock acquisition burns the coordinate: update the
exact Terraform input in a separately reviewed change before making another
request.

`0.0.22-private.1` is permanently consumed by failed build
`eef8312e-a31d-4d75-bc66-df3778fe5533`: it acquired the lock, promoted the four
image indexes and pushed the application chart before failing to record Helm's
stderr digest. It produced no CRD chart or release evidence and is not a valid
deployment input. `0.0.22-private.2` successfully proved the four runtime-image
copy rail but omitted the verifier required by the Cloud Deploy contract, so it
must not be admitted as a deployment input. The complete replacement coordinate
is `0.0.22-private.3`; the publisher must never overwrite or resume `.1` or
`.2`.

No GitHub Action, GHCR writer credential, public Artifact Registry IAM grant or
local Docker registry login participates in this release path.
