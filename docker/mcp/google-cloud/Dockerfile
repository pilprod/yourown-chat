ARG BUILD_IMAGE=node:22.23.1-alpine3.24@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2
ARG RUNTIME_IMAGE=node:local

FROM ${BUILD_IMAGE} AS dependencies

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force

FROM ${RUNTIME_IMAGE}

WORKDIR /app

USER root

COPY --from=dependencies --chown=65532:65532 /app/node_modules ./node_modules
COPY --chown=65532:65532 package.json package-lock.json ./
COPY artifact-vulnerability-client.mjs billing-cost-client.mjs \
  cloud-build-client.mjs cloud-deploy-client.mjs server.mjs \
  tool-name-compat.mjs tool-result.mjs ./

USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["node", "/app/server.mjs"]
