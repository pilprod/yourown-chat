ARG BASE_IMAGE=yourown-chat/base:local
FROM ${BASE_IMAGE}

ARG UV_VERSION=0.11.32

USER root

RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/uv \
    && /opt/uv/bin/pip install --no-cache-dir "uv==${UV_VERSION}"

ENV PATH="/opt/uv/bin:${PATH}"

USER 65532:65532
