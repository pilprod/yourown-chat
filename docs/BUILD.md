# Mattermost image CI

The platform builds one patched Mattermost image and promotes that exact tag
through the `mattermost` Cloud Deploy pipeline.

```text
pilprod/mattermost v*.*-patched
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

- the Cloud Build second-generation repository link to `pilprod/mattermost`;
- the `img-build` service account;
- the `^v.*-patched$` trigger;
- narrowly scoped permissions to push the image and create a release only in
  the `mattermost` pipeline.

The shared `pilprod-github` connection is authorized once in the Google Cloud
console and must have access to both `pilprod/mattermost` and
`pilprod/yourown-chat`.

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
5. passes the new tag to both dev and prod render parameters and records the
   source tag, commit, and digest in annotations.

The deployment is started only after the push succeeds. There is no need to
edit both Mattermost manifests or create a second platform tag for a normal
image upgrade.

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

## MCP image factory

MCP images use one declarative factory rather than per-image Cloud Build
snippets:

- `docker/images.tsv` separates the stable logical image name from its
  Artifact Registry path and describes build or mirror mode, Dockerfile,
  context, parent runtime, upstream source, change selector, audit, Cloud
  Deploy parameter, OCI metadata and optional external Git source/revision;
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
├── mcp-terraform
└── mcp-whatsapp-business
```

Each internal package gets an immutable `<git-sha>` tag and a moving `runtime`
tag used to resolve the newest approved digest. The runtime dependency graph
is:

```text
base (pinned Debian)
├── node
│   ├── mcp-google-cloud
│   └── mcp-whatsapp-business
└── python
```

Terraform MCP and cloudflared are entries of type `mirror`: their official
digests are copied byte-for-byte into Artifact Registry. Mattermost is built
and released by its separate source-repository pipeline.
