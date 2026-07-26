ARG BUILD_IMAGE=node:22.23.1-bookworm-slim@sha256:6c74791e557ce11fc957704f6d4fe134a7bc8d6f5ca4403205b2966bd488f6b3
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
COPY message-store.mjs secret-env.mjs server.mjs webhook.mjs ./

ENV NODE_ENV=production \
    PORT=3000

EXPOSE 3000

USER 65532:65532

ENTRYPOINT ["node", "/app/server.mjs"]
