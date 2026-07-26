ARG NODE_IMAGE=node:22.23.1-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3
ARG BASE_IMAGE=base:local

FROM ${NODE_IMAGE} AS language-runtime

FROM ${BASE_IMAGE}

USER root

# Runtime images do not install packages. Keep npm, npx, Corepack and their
# dependency trees in ephemeral build stages instead of publishing their CVEs
# in every Node service image.
COPY --from=language-runtime /usr/local/bin/node /usr/local/bin/node

ENV NODE_ENV=production \
    NODE_VERSION=22.23.1

USER 65532:65532
