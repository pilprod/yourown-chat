# RTCD security rebuild

The release pipeline builds RTCD from the exact Mattermost `v1.2.6` source
commit `b3dee597998db880193b2fe863752cbfae8cdc89`. It does not reuse or modify
the published Mattermost binary image.

`dependencies.patch` updates the Go toolchain and vulnerable transitive
dependencies while leaving RTCD application code unchanged. Cloud Build
clones the pinned commit, verifies the checkout, applies the patch, verifies
the resulting module graph, builds a non-root distroless image, and publishes
it to the private Artifact Registry. Cloud Deploy passes only its immutable
digest to Helm.

Pinned security build inputs:

- RTCD source: `v1.2.6` / `b3dee597998db880193b2fe863752cbfae8cdc89`
- Go: `1.25.12`
- Build image: `golang:1.25.12-bookworm` at the digest in `Dockerfile`
- Runtime image: `gcr.io/distroless/static` at the digest in `Dockerfile`
- Build version: `v1.2.6-yourown.1`

The source license explicitly distinguishes official Mattermost-compiled
binaries from third-party builds. Operating this image therefore requires
either a commercial Mattermost license that covers the build or compliance
with the source license (including AGPL obligations where applicable). The
upstream `LICENSE.txt` is copied into the image. This repository does not
reclassify the image as Mattermost's MIT-licensed official compiled binary.

When Mattermost publishes a fixed RTCD release, prefer returning to the
official signed upstream artifact after compatibility and vulnerability gates
pass. Until then, this fork is supported only for the pinned source and
dependency set above.
