# kagent fork preview publication

The kagent fork preview is published by a dedicated Cloud Build identity. The
app-gcp stack owns only its least-privilege infrastructure:

- `kagent-preview-publisher@yourown-chat.iam.gserviceaccount.com`;
- a private, versioned GCS evidence bucket with a one-year retention policy;
- an empty `kagent-ghcr-write` Secret Manager container;
- project-level `roles/logging.logWriter` for the publisher;
- bucket-level `roles/storage.objectCreator` for the publisher;
- secret-level `roles/secretmanager.secretAccessor` for the publisher;
- service-account-level `roles/iam.serviceAccountUser` for the app-gcp apply
  identity and only explicitly configured submitters.

Terraform never creates a secret version. After the infrastructure apply, an
owner creates a dedicated classic GitHub PAT with only `write:packages`, then
adds it as one exact Secret Manager version using an interactive, non-logging
command. Do not reuse a broad `gh` CLI OAuth token and never pass the token as a
Terraform input, variable, output, build substitution, command argument, or
repository file.

The build must reference the exact secret version resource name, not `latest`.
It writes receipts under a build-ID-specific object prefix. The publisher has
no object read, overwrite, or delete role. Images and charts are checked for
absence, built under unique candidate refs, verified by digest, then promoted
once to final preview refs. Source tags and GitHub releases are created only
after the GCS receipt has been downloaded and verified by the release owner.
