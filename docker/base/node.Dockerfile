ARG NODE_IMAGE=node:22.22.0-bookworm-slim@sha256:dd9d21971ec4395903fa6143c2b9267d048ae01ca6d3ea96f16cb30df6187d94
ARG BASE_IMAGE=yourown-chat-base:local

FROM ${NODE_IMAGE} AS language-runtime

FROM ${BASE_IMAGE}

USER root

COPY --from=language-runtime /usr/local/ /usr/local/

ENV NODE_ENV=production

USER 65532:65532
