# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:20-slim
ARG PYTHON_IMAGE=python:3.12-slim
ARG OCTOP_SOURCE_REPO=https://github.com/BlueSkyXN/Octop.git
ARG OCTOP_SOURCE_REF=d49e8dc57871ffe5d6e1ec754e41513c434ce5e2
ARG OCTOP_SOURCE_VERSION=1.0.2b5
ARG OCTOP_HARNESS_REF=418ce889db91b027e93f5f7b68d8b8efcef23208
ARG OCTOP_GATEWAY_REF=1ddcd5a6611bc3205d2b4fdc28c4387d6892f487
ARG OCTOP_MEMORY_REF=8b6abc3b6817f6b6d993d68190bc7ffc0a70dccf
ARG OCTOP_BROWSER_REF=bb26e92b1d3243be6c09530e7526f80bb1b69bda

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
ARG OCTOP_HARNESS_REF
ARG OCTOP_GATEWAY_REF
ARG OCTOP_MEMORY_REF
ARG OCTOP_BROWSER_REF
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
    OCTOP_HFS_COMPONENT_REFS="harness=${OCTOP_HARNESS_REF};gateway=${OCTOP_GATEWAY_REF};memory=${OCTOP_MEMORY_REF};browser=${OCTOP_BROWSER_REF}" \
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

RUN --mount=type=cache,target=/root/.cache/uv \
    export UV_CACHE_DIR=/root/.cache/uv \
    && if [ -n "${PIP_INDEX_URL}" ]; then \
        export UV_INDEX_URL="${PIP_INDEX_URL}"; \
        if [ -n "${PIP_TRUSTED_HOST}" ]; then export UV_INSECURE_HOST="${PIP_TRUSTED_HOST}"; fi; \
    fi \
    && uv sync --frozen --no-dev --extra browser \
    && uv pip install --no-deps \
        "octop-memory @ git+https://github.com/BlueSkyXN/octop-memory.git@${OCTOP_MEMORY_REF}" \
        "octop-browser @ git+https://github.com/BlueSkyXN/octop-browser.git@${OCTOP_BROWSER_REF}" \
    && set -eux; \
       export OCTOP_HARNESS_REF OCTOP_GATEWAY_REF OCTOP_MEMORY_REF OCTOP_BROWSER_REF; \
       python - <<'PYEOF'
import importlib.metadata as im
import json
import os

expected = {
    "octop-harness": os.environ["OCTOP_HARNESS_REF"],
    "octop-gateway": os.environ["OCTOP_GATEWAY_REF"],
    "octop-memory": os.environ["OCTOP_MEMORY_REF"],
    "octop-browser": os.environ["OCTOP_BROWSER_REF"],
}
for name, sha in expected.items():
    url = im.distribution(name).read_text("direct_url.json")
    assert url, name
    info = json.loads(url)
    assert info.get("url", "").startswith("https://github.com/BlueSkyXN/"), (name, info.get("url"))
    commit = info.get("vcs_info", {}).get("commit_id")
    assert commit == sha, (name, commit, sha)
print("component fork pins verified:", expected)
PYEOF
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

ENV XDG_CACHE_HOME=/tmp/octop-cache/xdg \
    UV_CACHE_DIR=/tmp/octop-cache/uv \
    PIP_CACHE_DIR=/tmp/octop-cache/pip \
    NPM_CONFIG_CACHE=/tmp/octop-cache/npm

USER 1000

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:${OCTOP_PORT:-7860}/api/health >/dev/null"]

ENTRYPOINT ["/usr/local/bin/octop-hfs-entrypoint"]
CMD []
