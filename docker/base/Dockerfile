FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

RUN apk upgrade --no-cache \
    && apk add --no-cache ca-certificates libatomic libstdc++ \
    && addgroup -g 65532 -S nonroot \
    && adduser -u 65532 -S -D -H -G nonroot \
      -s /sbin/nologin nonroot

# Keep project-wide runtime policy here so derived language images cannot
# drift. Language runtimes are added only by the child image that needs them.
ENV HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

USER 65532:65532
