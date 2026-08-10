ARG GO_BUILD_IMAGE=golang:1.26.5-alpine3.23@sha256:622e56dbc11a8cfe87cafa2331e9a201877271cbff918af53d3be315f3da88cc

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
