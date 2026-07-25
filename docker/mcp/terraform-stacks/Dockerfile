ARG RUNTIME_IMAGE=node:local
FROM ${RUNTIME_IMAGE}

WORKDIR /app

USER root

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force

COPY hcp-client.mjs server.mjs ./

ENV NODE_ENV=production \
    PORT=3000

EXPOSE 3000

USER 65532:65532

ENTRYPOINT ["node", "/app/server.mjs"]
