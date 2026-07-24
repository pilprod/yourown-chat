FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates libatomic1 libstdc++6 \
    && groupadd --gid 65532 nonroot \
    && useradd --uid 65532 --gid 65532 --home-dir /tmp \
      --shell /usr/sbin/nologin nonroot \
    && rm -rf /var/lib/apt/lists/*

# Keep project-wide runtime policy here so derived language images cannot
# drift. Language runtimes are added only by the child image that needs them.
ENV HOME=/tmp \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

USER 65532:65532
