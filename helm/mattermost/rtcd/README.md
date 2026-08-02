# RTCD integration lock

RTCD source, dependency hardening, and the Dockerfile belong to
[`pilprod/yourown-chat-rtcd`](https://github.com/pilprod/yourown-chat-rtcd).
This directory intentionally contains only `source.lock`, the deployment
allow-list for the exact source commit.

Cloud Build clones the repository from `RTCD_SOURCE_REPOSITORY`, checks out
the full `RTCD_SOURCE_COMMIT`, and fails if the checked-out commit or the
component Dockerfile differs. It then builds the non-root distroless image
inside our project, attaches SBOM/provenance, and Cloud Deploy receives only
its Artifact Registry digest.

Updating `source.lock` is a Mattermost release input, so it follows the same
dev-preview, verification, approval and production path as a server change.
Floating RTCD branches, upstream images, and `latest` tags are not deployable.
