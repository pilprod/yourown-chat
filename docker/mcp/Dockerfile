ARG GO_BUILD_IMAGE=golang:1.26.6-alpine3.23@sha256:e57c41c1d5864341031181b0db34b9a537bb5773eb6428e4e5bdaea0f9135406

FROM ${GO_BUILD_IMAGE} AS build

ARG SERVICE
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY cmd ./cmd
COPY internal ./internal

RUN case "${SERVICE}" in google-cloud|terraform-stacks) ;; *) exit 64 ;; esac \
    && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
      -buildvcs=false -trimpath \
      -ldflags="-s -w -buildid=" \
      -o /out/mcp-server "./cmd/${SERVICE}"

FROM scratch

COPY --from=build /etc/os-release /etc/os-release
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build --chown=65532:65532 /out/mcp-server /mcp-server

USER 65532:65532

ENTRYPOINT ["/mcp-server"]
