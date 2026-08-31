# Private Substrate release handoff

Substrate deployment artifacts stay private. GitHub is read-only source and the
public, digest-qualified `v0.0.22` release is only the input to a Google Cloud
handoff. The app-gcp publisher copies the exact image indexes, reproduces the
two charts from the reviewed source tree, scans both runnable architectures and
publishes passing artifacts into the existing private Google Artifact Registry.

The applied input authorizes exactly this first handoff:

```text
source tag:      v0.0.22
tag object:      00a6a684cea3b3feea67461cf79347332ec759ef
source commit:   e9ed68e587b56df2aa2a7f0267a744598c4d48b4
release version: 0.0.22-private.1
release prefix:  europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate
staging prefix:  europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/substrate
```

The publisher does not create a second evidence bucket. It depends on and
reuses the private, versioned kagent evidence bucket, with Substrate receipts
isolated below `substrate/<release-version>/`.

## Release sequence

1. Apply the app-gcp configuration that materializes the dedicated service
   account, repository-scoped writers, scanner grant and IAM-protected Pub/Sub
   trigger.
2. Submit the one authorized coordinate:

   ```bash
   terraform/app-gcp/modules/substrate-preview-publisher/scripts/publish-release-request.sh \
     0.0.22-private.1
   ```

3. Follow the Cloud Build through Google Cloud MCP. Do not open kagent bootstrap
   or delivery gates until the build succeeds and the receipt checksum is
   verified.
4. Copy only digest-qualified image and OCI chart references from:

   ```text
   gs://yourown-chat-kagent-preview-evidence-europe-west3/substrate/0.0.22-private.1/
   ```

5. Copy the build's exact generation-qualified `evidence_uri` into
   `kagent_preview_publisher.substrate_release_evidence_uri`, apply that input,
   and only then submit the reviewed `.kap.3` kagent release. Its build identity
   reads the private object and obtains a short-lived Artifact Registry token;
   the verifier receives those values only as ephemeral files inside Cloud
   Build. An empty URI makes kagent publication fail closed.

The build stages exact source indexes into the disposable private repository,
verifies both `linux/amd64` and `linux/arm64` manifests, blocks High or Critical
findings, then acquires a generation-zero release lock before writing final
references. It publishes no `latest` tag. A failure after lock acquisition burns
the coordinate: update the exact Terraform input in a separately reviewed
change before making another request.

No GitHub Action, GHCR writer credential, public Artifact Registry IAM grant or
local Docker registry login participates in this release path.
