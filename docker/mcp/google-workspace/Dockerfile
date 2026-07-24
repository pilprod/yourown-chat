ARG RUNTIME_IMAGE=yourown-chat-python:local
FROM ${RUNTIME_IMAGE}

WORKDIR /app

USER root

COPY --chown=65532:65532 . .

RUN /opt/uv/bin/uv sync --python /usr/bin/python3 --frozen --no-dev --extra disk \
    && rm -rf /root/.cache /tmp/*

EXPOSE 8000

USER 65532:65532

ENTRYPOINT ["/app/.venv/bin/python", "/app/main.py"]
CMD ["--transport", "streamable-http"]
