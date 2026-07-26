FROM debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

RUN apt-get update \
    && apt-get upgrade --yes --no-install-recommends \
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
