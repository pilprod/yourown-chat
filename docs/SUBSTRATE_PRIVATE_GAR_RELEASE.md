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
The Terraform consumer admits schema v2 only for the exact successful
`.private.3` evidence checksum, both private chart digests, all five private
image digests, and the corresponding Helm values. Bootstrap and release remain
disabled until their separate deployment reviews open those gates.

## Release sequence

1. Apply the app-gcp configuration that materializes the dedicated service
   account, repository-scoped writers, scanner grant and IAM-protected Pub/Sub
   trigger.
2. Submit the one authorized coordinate:

   ```bash
   terraform/app-gcp/modules/substrate-preview-publisher/scripts/publish-release-request.sh \
     0.0.22-private.3
   ```

3. Follow the Cloud Build through Google Cloud MCP. Build
   `5df39e89-983c-45bd-9d18-7aab8876f104` completed successfully; its evidence
   and receipt checksums were verified before this consumer pin was opened.
4. Copy only digest-qualified image and OCI chart references from:

   ```text
   gs://yourown-chat-kagent-preview-evidence-europe-west3/substrate/0.0.22-private.3/
   ```

5. Keep the exact generation-qualified evidence URI, reviewed kagent source
   commit, publisher URI validation, and release-scoped GCS IAM prefix in one
   successor change. The current pin is
   `release-evidence.json#1788220783329855` with SHA-256
   `b5aad6d44d359cd63fb2753c000579d948b1bb70c94bf0fbc3cdf21698c9789b`;
   the successor kagent tag is `gcp-v0.0.0-external-slot.kap.5`. Its build
   identity reads the private object and obtains a short-lived Artifact
   Registry token; the verifier receives those values only as ephemeral files
   inside Cloud Build. An empty or different URI makes publication fail closed.

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
is `0.0.22-private.3`; it copied and scanned all five dual-platform indexes,
published both charts, and retained generation-qualified evidence. The
publisher must never overwrite or resume `.1`, `.2`, or `.3`.

No GitHub Action, GHCR writer credential, public Artifact Registry IAM grant or
local Docker registry login participates in this release path.
