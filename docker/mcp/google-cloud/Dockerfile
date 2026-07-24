ARG RUNTIME_IMAGE=yourown-chat-node:local
FROM ${RUNTIME_IMAGE}

WORKDIR /app

USER root

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
    && npm cache clean --force

USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/app/node_modules/.bin/supergateway"]
CMD ["--stdio", "node /app/node_modules/@google-cloud/observability-mcp/dist/bundle.js", "--outputTransport", "streamableHttp", "--stateful", "--port", "8080", "--healthEndpoint", "/healthz"]
