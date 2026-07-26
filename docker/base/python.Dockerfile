ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.32@sha256:df4cae8f3a96d175e2e5f992e597550000edbe78fdc2594d5cd8de1a217f504c
ARG BASE_IMAGE=base:local

FROM ${UV_IMAGE} AS uv-runtime

FROM ${BASE_IMAGE}

USER root

RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy the official standalone binaries. A runtime Python image does not need
# pip, setuptools, wheel, or a virtualenv containing their vulnerable metadata.
COPY --from=uv-runtime /uv /uvx /usr/local/bin/

USER 65532:65532
