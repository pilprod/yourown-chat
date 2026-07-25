ARG UPSTREAM_IMAGE
ARG RUNTIME_IMAGE=base:local

FROM ${UPSTREAM_IMAGE} AS upstream

FROM ${RUNTIME_IMAGE}

USER root

COPY --from=upstream /bin/terraform-mcp-server /bin/terraform-mcp-server
COPY entrypoint.sh /usr/local/bin/terraform-mcp-entrypoint

RUN chmod 0555 /bin/terraform-mcp-server /usr/local/bin/terraform-mcp-entrypoint

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/terraform-mcp-entrypoint"]
