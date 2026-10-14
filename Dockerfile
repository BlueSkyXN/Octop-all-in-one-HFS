# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:20-slim
ARG PYTHON_IMAGE=python:3.12-slim
ARG OCTOP_SOURCE_REPO=https://github.com/TencentCloud/Octop.git
ARG OCTOP_SOURCE_REF=664c1fb38e354ea987041aa14b151e20d15ce71f
ARG OCTOP_SOURCE_VERSION=1.0.2b7
ARG OCTOP_HARNESS_VERSION=1.0.2
ARG OCTOP_GATEWAY_VERSION=1.0.0
ARG OCTOP_MEMORY_VERSION=1.0.1
ARG OCTOP_BROWSER_VERSION=1.0.0

FROM ${NODE_IMAGE} AS source

ARG OCTOP_SOURCE_REPO
ARG OCTOP_SOURCE_REF
ARG OCTOP_SOURCE_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY patches/disable-remote-desktop.patch /tmp/disable-remote-desktop.patch
COPY patches/enforce-persistent-workspaces.patch /tmp/enforce-persistent-workspaces.patch

RUN set -eux; \
    printf '%s' "${OCTOP_SOURCE_REF}" | grep -Eq '^[0-9a-f]{40}$'; \
    git init .; \
    git remote add origin "${OCTOP_SOURCE_REPO}"; \
    git fetch --depth 1 origin "${OCTOP_SOURCE_REF}"; \
    git checkout --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "${OCTOP_SOURCE_REF}"; \
    test "$(awk -F'\"' '/^version = / { print $2; exit }' pyproject.toml)" = "${OCTOP_SOURCE_VERSION}"; \
    git apply --check /tmp/disable-remote-desktop.patch; \
    git apply /tmp/disable-remote-desktop.patch; \
    git apply --check /tmp/enforce-persistent-workspaces.patch; \
    git apply /tmp/enforce-persistent-workspaces.patch; \
    printf '%s\n' "${OCTOP_SOURCE_REF}" > .octop-upstream-ref; \
    rm -rf .git \
        /tmp/disable-remote-desktop.patch \
        /tmp/enforce-persistent-workspaces.patch

FROM source AS frontend-builder

ARG NPM_REGISTRY=
ARG NODE_MAX_OLD_SPACE_SIZE=2048

WORKDIR /src/dashboard

RUN --mount=type=cache,target=/root/.npm \
    if [ -n "${NPM_REGISTRY}" ]; then npm config set registry "${NPM_REGISTRY}"; fi \
    && npm ci --prefer-offline --no-audit

RUN mkdir -p ../src/octop/dashboard \
    && NODE_ENV=production \
       NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}" \
       npm run build:docker

FROM ${PYTHON_IMAGE} AS runtime

ARG OCTOP_SOURCE_REPO
ARG OCTOP_SOURCE_REF
ARG OCTOP_SOURCE_VERSION
ARG OCTOP_HARNESS_VERSION
ARG OCTOP_GATEWAY_VERSION
ARG OCTOP_MEMORY_VERSION
ARG OCTOP_BROWSER_VERSION
ARG PIP_INDEX_URL=
ARG PIP_TRUSTED_HOST=

LABEL org.opencontainers.image.title="Octop All-in-One HFS" \
      org.opencontainers.image.description="Octop preview packaged for a Hugging Face Docker Space" \
      org.opencontainers.image.source="https://github.com/BlueSkyXN/Octop-all-in-one-HFS" \
      org.opencontainers.image.revision="${OCTOP_SOURCE_REF}" \
      org.opencontainers.image.version="${OCTOP_SOURCE_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MIT" \
      com.blueskyxn.hfs.remote-desktop="disabled"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/data \
    OCTOP_HOME=/data/.octop \
    OCTOP_BIND_HOST=0.0.0.0 \
    OCTOP_PORT=7860 \
    OCTOP_LOG_LEVEL=info \
    OCTOP_HFS_MOUNT=/data \
    OCTOP_PERSISTENT_ROOT=/data \
    OCTOP_BACKUP_AUTO_ENABLED=true \
    OCTOP_BACKUP_SCHEDULE="cron:0 4 * * *" \
    OCTOP_BACKUP_RETENTION_COUNT=7 \
    OCTOP_HFS_UPSTREAM_REPO=${OCTOP_SOURCE_REPO} \
    OCTOP_HFS_UPSTREAM_REF=${OCTOP_SOURCE_REF} \
    OCTOP_HFS_UPSTREAM_VERSION=${OCTOP_SOURCE_VERSION} \
    OCTOP_HFS_COMPONENT_VERSIONS="harness=${OCTOP_HARNESS_VERSION};gateway=${OCTOP_GATEWAY_VERSION};memory=${OCTOP_MEMORY_VERSION};browser=${OCTOP_BROWSER_VERSION}" \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        git \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:0.7 /uv /uvx /bin/

WORKDIR /app

COPY --from=source /src/pyproject.toml /src/uv.lock /src/README.md /src/LICENSE ./

RUN --mount=type=cache,target=/root/.cache/uv \
    export UV_CACHE_DIR=/root/.cache/uv \
    && if [ -n "${PIP_INDEX_URL}" ]; then \
        export UV_INDEX_URL="${PIP_INDEX_URL}"; \
        if [ -n "${PIP_TRUSTED_HOST}" ]; then export UV_INSECURE_HOST="${PIP_TRUSTED_HOST}"; fi; \
    fi \
    && uv sync --frozen --no-install-project --no-dev --extra browser

ENV PATH="/app/.venv/bin:${PATH}"

COPY --from=source /src/src/ ./src/
COPY --from=frontend-builder /src/src/octop/dashboard/ ./src/octop/dashboard/
COPY --from=source /src/docker/docker-entrypoint.sh /usr/local/bin/octop-upstream-entrypoint
COPY --from=source /src/.octop-upstream-ref /app/.octop-upstream-ref
COPY entrypoint.sh /usr/local/bin/octop-hfs-entrypoint
COPY scripts/verify_hfs_runtime.py /app/verify_hfs_runtime.py

RUN --mount=type=cache,target=/root/.cache/uv \
    export UV_CACHE_DIR=/root/.cache/uv \
    && if [ -n "${PIP_INDEX_URL}" ]; then \
        export UV_INDEX_URL="${PIP_INDEX_URL}"; \
        if [ -n "${PIP_TRUSTED_HOST}" ]; then export UV_INSECURE_HOST="${PIP_TRUSTED_HOST}"; fi; \
    fi \
    && uv sync --frozen --no-dev --extra browser \
    && playwright install --with-deps chromium \
    && apt-get update \
    && apt-get install -y --no-install-recommends fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/* /tmp/* \
    && if command -v Xvnc >/dev/null 2>&1 || command -v Xtigervnc >/dev/null 2>&1; then \
         echo "HFS build invariant failed: VNC server binary is present" >&2; \
         exit 1; \
       fi \
    && test "$(python -c 'import importlib.metadata; print(importlib.metadata.version("octop"))')" = "${OCTOP_SOURCE_VERSION}" \
    && chmod +x /usr/local/bin/octop-upstream-entrypoint /usr/local/bin/octop-hfs-entrypoint \
    && if ! getent passwd 1000 >/dev/null; then useradd --create-home --uid 1000 user; fi \
    && mkdir -p /data/.octop /home/user /opt/ms-playwright \
    && chown -R 1000:1000 /data /home/user /opt/ms-playwright

RUN python - <<'PY'
import os
from pathlib import Path

from octop.infra.agents.workspace.dir import resolve_workspace_host_path

inside = Path("/data/.octop/agents/hfs-build-probe")
assert resolve_workspace_host_path(str(inside)) == inside
try:
    resolve_workspace_host_path("/tmp/hfs-build-probe")
except ValueError as exc:
    assert "must be under persistent root" in str(exc)
else:
    raise AssertionError("workspace outside /data was accepted")

os.environ.pop("OCTOP_PERSISTENT_ROOT")
assert resolve_workspace_host_path("/tmp/hfs-build-probe") == Path("/tmp/hfs-build-probe")
PY

RUN python /app/verify_hfs_runtime.py

ENV XDG_CACHE_HOME=/tmp/octop-cache/xdg \
    UV_CACHE_DIR=/tmp/octop-cache/uv \
    PIP_CACHE_DIR=/tmp/octop-cache/pip \
    NPM_CONFIG_CACHE=/tmp/octop-cache/npm

# The Feishu/WeCom CLI connectors need the lark-cli binary. The container runs
# as UID 1000, so neither apt nor a global npm install is possible at runtime —
# Node.js, npm, and the pinned CLI are baked into the image instead. The
# build-time npm cache follows NPM_CONFIG_CACHE into /tmp/octop-cache/npm and is
# removed by this layer.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends nodejs npm \
    && npm install -g @larksuite/cli@1.0.98 \
    && lark-cli --version \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# usque: userspace Cloudflare WARP client. The model-egress path to
# gateway.ai.cloudflare.com rides the WARP tunnel so the shared HF egress
# IP cannot be rate-limited/blackholed at the CF edge. Pinned release +
# SHA256, same artifacts as CPA-HFS-2026-PRO.
ARG USQUE_VERSION=4.2.1
RUN set -eu; \
    apt-get update \
    && apt-get install -y --no-install-recommends unzip \
    && rm -rf /var/lib/apt/lists/*; \
    ARCH="$(dpkg --print-architecture)"; \
    case "$ARCH" in \
      amd64) USQUE_ARCH=amd64; USQUE_SHA256=4117e20695078af9c11edecd1a826c009bbc7ea0b7f64458612b4198910bc313 ;; \
      arm64) USQUE_ARCH=arm64; USQUE_SHA256=c88b061c2a567f30813d7505637d1fb6fe7ec5898b5b61fd05122409fa5ad925 ;; \
      *) echo "Unsupported architecture for usque: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/usque.zip \
      "https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}/usque_${USQUE_VERSION}_linux_${USQUE_ARCH}.zip"; \
    echo "$USQUE_SHA256  /tmp/usque.zip" | sha256sum -c -; \
    unzip -q /tmp/usque.zip usque -d /usr/local/bin; \
    chmod +x /usr/local/bin/usque; \
    rm -f /tmp/usque.zip; \
    usque --help >/dev/null 2>&1 || true

USER 1000

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:${OCTOP_PORT:-7860}/api/health >/dev/null"]

ENTRYPOINT ["/usr/local/bin/octop-hfs-entrypoint"]
CMD []
