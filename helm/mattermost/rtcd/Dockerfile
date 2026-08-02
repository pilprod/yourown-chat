# Reproducible security rebuild of the exact Mattermost RTCD v1.2.6 source.
# The source tree is prepared and verified by Cloud Build before this stage.
FROM golang:1.25.12-bookworm@sha256:ea341baa9bd5ba6784f6d7161ace70544349a6242d54d34a0fbfd2c4d51c9d58 AS builder

ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG RTCD_UPSTREAM_COMMIT=b3dee597998db880193b2fe863752cbfae8cdc89
ARG RTCD_BUILD_VERSION=v1.2.6-yourown.1
ARG RTCD_BUILD_DATE=2026-06-29T23:15:03Z

ENV CGO_ENABLED=0
WORKDIR /src
COPY . .

RUN go mod verify && \
    go test -mod=readonly -run '^$' ./... && \
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" \
    go build -mod=readonly -trimpath \
      -ldflags="-s -w \
        -X github.com/mattermost/rtcd/service.buildHash=${RTCD_UPSTREAM_COMMIT} \
        -X github.com/mattermost/rtcd/service.buildVersion=${RTCD_BUILD_VERSION} \
        -X github.com/mattermost/rtcd/service.buildDate=${RTCD_BUILD_DATE} \
        -X github.com/mattermost/rtcd/service.goVersion=1.25.12" \
      -o /out/rtcd ./cmd/rtcd

FROM gcr.io/distroless/static@sha256:d6fa9db9548b5772860fecddb11d84f9ebd7e0321c0cb3c02870402680cc315f

LABEL org.opencontainers.image.title="YourOwn.Chat RTCD security rebuild" \
      org.opencontainers.image.version="v1.2.6-yourown.1" \
      org.opencontainers.image.revision="b3dee597998db880193b2fe863752cbfae8cdc89" \
      org.opencontainers.image.source="https://github.com/mattermost/rtcd" \
      org.opencontainers.image.licenses="LicenseRef-Mattermost-Commercial-OR-AGPL-3.0"

COPY --from=builder /out/rtcd /opt/rtcd/bin/rtcd
COPY --from=builder /src/build/group /src/build/passwd /etc/
COPY --from=builder /src/LICENSE.txt /licenses/rtcd/LICENSE.txt

USER calls
WORKDIR /opt/rtcd/bin
ENTRYPOINT ["./rtcd"]
