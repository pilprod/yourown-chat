# Mattermost image CI

Независимая сборка пользовательской серверной части и двух исполнителей
агентов, проверка их точных контрольных сумм и выпуск с подтверждением описаны в
[AGENT_PLATFORM_BUILD_RELEASE.md](AGENT_PLATFORM_BUILD_RELEASE.md).

The platform builds one patched Mattermost image and promotes its exact digest
through the `mattermost` Cloud Deploy pipeline.

```text
pilprod/yourown-chat-mattermost v*.*-patched
  -> Cloud Build
  -> Artifact Registry docker/mattermost:<tag>
  -> Cloud Deploy mattermost/dev
  -> migration + ping smoke
  -> approval
  -> dev Mattermost scaled to 0
  -> mattermost/prod rolling rollout
```

## Provisioned resources

The `platform-gcp` stack owns the Artifact Registry repository. The `app-gcp`
stack owns:

- the Cloud Build second-generation repository link to `pilprod/yourown-chat-mattermost`;
- the `img-build` service account;
- a `release-X.Y-patched` branch trigger targeting the structurally dev-only
  `mattermost-preview` pipeline;
- the `^vX.Y.Z-patched$` tag trigger targeting the normal `mattermost`
  dev-to-prod pipeline;
- narrowly scoped permissions to push the image and create releases only in
  those two pipelines.

The shared `pilprod-github` connection is authorized once in the Google Cloud
console and must have access to `pilprod/yourown-chat-mattermost`,
`pilprod/yourown-chat`, the product backend `pilprod/yourown-chat-server`, and
the agent workloads `pilprod/yourown-chat-agents`.

## Build and deliver

```bash
git tag v9.11.3-patched
git push origin v9.11.3-patched
```

The build:

1. builds and pushes
   `europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost:$TAG_NAME`;
2. resolves its digest;
3. clones `pilprod/yourown-chat` at `main`;
4. creates a `mattermost` release from `helm/`;
5. passes `repository@sha256:...` to dev and the same `sha256:...` to the
   Mattermost Operator's digest-aware `spec.version` in prod;
6. records the source tag, commit, build ID, and digest in the release identity
   and annotations.

Resolving the tag before creating the release is mandatory. Reusing a mutable
tag string in a Deployment pod template does not create a new ReplicaSet when
the registry moves that tag to another digest.

The deployment is started only after the push succeeds. There is no need to
edit both Mattermost manifests or create a second platform tag for a normal
image upgrade.

For iterative testing, push to `release-11.9-patched`. Each commit is tagged
in Artifact Registry as `git-<full SHA>` and deployed only through
`mattermost-preview-dev`. The preview Cloud Deploy pipeline has no prod target.
After review, put `vX.Y.Z-patched` on the exact accepted commit to enter the
production-capable flow.

Verify the artifact:

```bash
gcloud artifacts docker images list \
  europe-west3-docker.pkg.dev/yourown-chat/docker/mattermost \
  --project=yourown-chat
```

Then inspect the automatically created release:

```bash
gcloud deploy releases list \
  --delivery-pipeline=mattermost \
  --region=europe-west3
```

The dev PostgreSQL database is not part of this release. It remains running as
the Terraform-managed `dev-postgres` StatefulSet so startup validates
sequential database migrations. After the smoke passes, dev Mattermost remains
available for review. Approving production starts an external Cloud Deploy
predeploy hook, which scales only dev Mattermost to zero immediately before the
production rollout. Its Skaffold custom-action container runs in Cloud Build
under a dedicated Google service account; it does not create a cleanup pod in
GKE.

## Platform tags

A semver tag in `pilprod/yourown-chat` remains the release mechanism for
manifest or delivery changes. Its diff router creates a Mattermost release only
when Mattermost paths changed. See [DEPLOY.md](DEPLOY.md).

Once a tag starts any Cloud Build release process it is immutable, including
when that process fails. Publish a new semver tag for the corrected commit.
Deleting and recreating a tag is allowed only when Cloud Build has never
started for it and Cloud Deploy has no release derived from it.

## Image factories and private MCP source

The image catalog owns public runtimes and vendor source rebuilds. First-party
MCP application code lives only in the private `pilprod/yourown-chat-mcp`
repository. Its Terraform-managed Cloud Build trigger uses the single
parameterized `docker/mcp/Dockerfile` in this repository to build two separate
static Go images, attest them, scan them and release immutable source tags.

- `docker/images.tsv` separates the stable logical image name from its
  Artifact Registry path and describes build or mirror mode, Dockerfile,
  context, parent runtime, upstream source, change selector, audit, Cloud
  Deploy parameter and OCI metadata;
- `docker/prepare-images.sh` materialises every catalogued external build
  context at its pinned revision;
- `docker/audit-images.sh` applies the catalogued language audit policy;
- `docker/build-images.sh` resolves the dependency graph, bootstraps missing
  images, and publishes immutable plus `runtime` tags;
- `docker/deploy-parameters.sh` resolves catalogued images to digests and
  generates the Cloud Deploy parameter list.

Artifact Registry keeps each independently deployable image as a flat package:

```text
docker/                         # one Artifact Registry repository
├── mattermost
├── base
├── node
├── python
├── mcp-cloudflared
├── mcp-google-cloud
├── mcp-terraform-stacks
├── yourown-chat-control-api
├── yourown-chat-workflow-worker
└── yourown-chat-activity-worker
```

`yourown-chat-control-api` is built from `pilprod/yourown-chat-server`.
`yourown-chat-workflow-worker` and `yourown-chat-activity-worker` are built from
`pilprod/yourown-chat-agents`. Separate Cloud Build identities and triggers
enforce this source boundary. Matching immutable tags coordinate the three
digests into one workload release.

Owned MCP images are built directly from the private Go source repository with
one pinned multi-service Dockerfile. The retained base/runtime catalog is for
vendor and other application images; it is not an MCP source dependency:

```text
yourown-chat-mcp tag
  -> mcp-google-cloud@sha256:...
  -> mcp-terraform-stacks@sha256:...
```

Cloudflared is built from the exact commit behind an official release tag with
a pinned patched Go toolchain because the corresponding upstream container can
lag a Go security patch. Mattermost is built and released by its separate
source-repository pipeline.
