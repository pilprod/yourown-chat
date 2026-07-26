ARG GO_IMAGE=golang:1.26.5-bookworm@sha256:1ecb7edf62a0408027bd5729dfd6b1b8766e578e8df93995b225dfd0944eb651

FROM ${GO_IMAGE} AS builder

ARG UPSTREAM_VERSION

ENV CGO_ENABLED=0 \
    CONTAINER_BUILD=1

WORKDIR /go/src/github.com/cloudflare/cloudflared

COPY . .

# Build the unmodified official release source with the first Go patch that
# fixes the 1.26.4 standard-library vulnerabilities present upstream. The
# shallow commit checkout intentionally has no local Git tag, so the catalogued
# release version is injected explicitly into the official Makefile.
RUN test -n "${UPSTREAM_VERSION}" \
    && make VERSION="${UPSTREAM_VERSION}" cloudflared

FROM gcr.io/distroless/base-debian13:nonroot@sha256:b78832f41c8128046807c24840ebee4f1c18ba7870eed423d8750c272c15e147

COPY --from=builder --chown=65532:65532 \
  /go/src/github.com/cloudflare/cloudflared/cloudflared \
  /usr/local/bin/cloudflared

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/cloudflared", "--no-autoupdate"]
CMD ["version"]
