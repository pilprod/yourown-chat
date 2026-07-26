ARG RUNTIME_IMAGE=node:local
FROM ${RUNTIME_IMAGE}

WORKDIR /app

USER root

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force

COPY artifact-vulnerability-client.mjs cloud-deploy-client.mjs server.mjs tool-result.mjs ./

USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/app/node_modules/.bin/supergateway"]
CMD ["--stdio", "node /app/server.mjs", "--outputTransport", "streamableHttp", "--stateful", "--port", "8080", "--healthEndpoint", "/healthz"]
