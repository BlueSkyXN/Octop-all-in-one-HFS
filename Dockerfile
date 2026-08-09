# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:20-slim
ARG PYTHON_IMAGE=python:3.12-slim
ARG OCTOP_SOURCE_REPO=https://github.com/TencentCloud/Octop.git
ARG OCTOP_SOURCE_REF=8d0503079f5dd1e66b2b0320e0ed405c46d1cd0b
ARG OCTOP_SOURCE_VERSION=0.9.19

FROM ${NODE_IMAGE} AS source

ARG OCTOP_SOURCE_REPO
ARG OCTOP_SOURCE_REF
ARG OCTOP_SOURCE_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN set -eux; \
    printf '%s' "${OCTOP_SOURCE_REF}" | grep -Eq '^[0-9a-f]{40}$'; \
    git init .; \
    git remote add origin "${OCTOP_SOURCE_REPO}"; \
    git fetch --depth 1 origin "${OCTOP_SOURCE_REF}"; \
    git checkout --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "${OCTOP_SOURCE_REF}"; \
    test "$(awk -F'\"' '/^version = / { print $2; exit }' pyproject.toml)" = "${OCTOP_SOURCE_VERSION}"; \
    printf '%s\n' "${OCTOP_SOURCE_REF}" > .octop-upstream-ref; \
    rm -rf .git

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
       npx vite build

FROM ${PYTHON_IMAGE} AS runtime

ARG OCTOP_SOURCE_REPO
ARG OCTOP_SOURCE_REF
ARG OCTOP_SOURCE_VERSION
ARG PIP_INDEX_URL=
ARG PIP_TRUSTED_HOST=

LABEL org.opencontainers.image.title="Octop All-in-One HFS" \
      org.opencontainers.image.description="Octop preview packaged for a Hugging Face Docker Space" \
      org.opencontainers.image.source="https://github.com/BlueSkyXN/Octop-all-in-one-HFS" \
      org.opencontainers.image.revision="${OCTOP_SOURCE_REF}" \
      org.opencontainers.image.version="${OCTOP_SOURCE_VERSION}" \
      org.opencontainers.image.licenses="GPL-3.0-only AND MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/data \
    OCTOP_BIND_HOST=0.0.0.0 \
    OCTOP_PORT=7860 \
    OCTOP_LOG_LEVEL=info \
    OCTOP_HFS_UPSTREAM_REPO=${OCTOP_SOURCE_REPO} \
    OCTOP_HFS_UPSTREAM_REF=${OCTOP_SOURCE_REF} \
    OCTOP_HFS_UPSTREAM_VERSION=${OCTOP_SOURCE_VERSION} \
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
    if [ -n "${PIP_INDEX_URL}" ]; then \
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
    if [ -n "${PIP_INDEX_URL}" ]; then \
        export UV_INDEX_URL="${PIP_INDEX_URL}"; \
        if [ -n "${PIP_TRUSTED_HOST}" ]; then export UV_INSECURE_HOST="${PIP_TRUSTED_HOST}"; fi; \
    fi \
    && uv sync --frozen --no-dev --extra browser \
    && playwright install --with-deps chromium \
    && apt-get update \
    && apt-get install -y --no-install-recommends fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/* /tmp/* \
    && test "$(python -c 'import importlib.metadata; print(importlib.metadata.version("octop"))')" = "${OCTOP_SOURCE_VERSION}" \
    && chmod +x /usr/local/bin/octop-upstream-entrypoint /usr/local/bin/octop-hfs-entrypoint \
    && if ! getent passwd 1000 >/dev/null; then useradd --create-home --uid 1000 user; fi \
    && mkdir -p /data/.octop /home/user /opt/ms-playwright \
    && chown -R 1000:1000 /data /home/user /opt/ms-playwright

USER 1000

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:${OCTOP_PORT:-7860}/api/health >/dev/null"]

ENTRYPOINT ["/usr/local/bin/octop-hfs-entrypoint"]
CMD []
