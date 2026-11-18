# The bridge in a container: Python slim, the pinned Python packages, and (optionally) the official Codex CLI.
#   docker build -t gpt-live-bridge .                                  # with Codex CLI
#   docker build --build-arg CODEX_VERSION= -t gpt-live-bridge .       # without; mount your own and set CODEX_BIN
# Everything the bridge keeps (chat history, the Codex login, the web app) lives in the /data volume.
FROM python:3.12-slim

ARG CODEX_VERSION=0.168.0
ARG TARGETARCH

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/data \
    BRIDGE_HOST=0.0.0.0 \
    BRIDGE_PORT=8787 \
    BRIDGE_DATA_DIR=/data \
    CODEX_HOME=/data/codex-home \
    CODEX_BIN=/usr/local/bin/codex

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    if [ -n "$CODEX_VERSION" ]; then \
        case "${TARGETARCH:-amd64}" in \
            amd64) arch=x86_64 ;; \
            arm64) arch=aarch64 ;; \
            *) echo "no Codex CLI build for $TARGETARCH; build with --build-arg CODEX_VERSION= and mount one" >&2; exit 1 ;; \
        esac; \
        curl -fsSL "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-${arch}-unknown-linux-musl.tar.gz" \
            | tar -xz -C /tmp; \
        install -m 0755 "/tmp/codex-${arch}-unknown-linux-musl" /usr/local/bin/codex; \
        rm -f /tmp/codex-*; \
        /usr/local/bin/codex --version; \
    fi; \
    apt-get purge -y curl; apt-get autoremove -y; rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --only-binary=:all: -r requirements.txt
COPY gpt-live-bridge.py tove_pair.py hermes-live.html *-prompt.md ./

RUN useradd --system --uid 10001 --user-group --home-dir /data --shell /usr/sbin/nologin bridge \
    && install -d -o bridge -g bridge -m 0700 /data /data/codex-home /data/work
USER bridge
VOLUME ["/data"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.environ.get('BRIDGE_PORT', '8787'), timeout=4)"]

CMD ["python", "/app/gpt-live-bridge.py"]
