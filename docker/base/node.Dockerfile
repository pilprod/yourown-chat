ARG NODE_IMAGE=node:22.23.1-alpine3.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2
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

RUN node --version

USER 65532:65532
