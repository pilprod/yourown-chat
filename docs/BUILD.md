# Mattermost image CI

The platform builds one patched Mattermost image and promotes that exact tag
through the `mattermost` Cloud Deploy pipeline.

```text
pilprod/mattermost v*.*-patched
  -> Cloud Build
  -> Artifact Registry docker/mattermost:<tag>
  -> Cloud Deploy mattermost/dev
  -> migration + ping smoke
  -> dev Mattermost scaled to 0
  -> approval
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
sequential database migrations. After the smoke passes, only dev Mattermost is
scaled to zero.

## Platform tags

A semver tag in `pilprod/yourown-chat` remains the release mechanism for
manifest or delivery changes. Its diff router creates a Mattermost release only
when Mattermost paths changed. See [DEPLOY.md](DEPLOY.md).
