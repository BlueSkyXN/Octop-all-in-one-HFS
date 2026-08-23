# syntax=docker/dockerfile:1.7

ARG NODE_IMAGE=node:20-slim
ARG PYTHON_IMAGE=python:3.12-slim
ARG OCTOP_SOURCE_REPO=https://github.com/TencentCloud/Octop.git
ARG OCTOP_SOURCE_REF=bfe017adc183cbce7fbd6ca57b050d925a015ee0
ARG OCTOP_SOURCE_VERSION=0.9.25

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
       npm run build:docker

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
    OCTOP_HOME=/data/.octop \
    OCTOP_BIND_HOST=0.0.0.0 \
    OCTOP_PORT=7860 \
    OCTOP_LOG_LEVEL=info \
    OCTOP_HFS_UPSTREAM_REPO=${OCTOP_SOURCE_REPO} \
    OCTOP_HFS_UPSTREAM_REF=${OCTOP_SOURCE_REF} \
    OCTOP_HFS_UPSTREAM_VERSION=${OCTOP_SOURCE_VERSION} \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    DISPLAY=:99 \
    OCTOP_DESKTOP_DISPLAY=:99 \
    OCTOP_DESKTOP_GEOMETRY=1920x1080

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
    && uv sync --frozen --no-install-project --no-dev --extra browser --extra desktop

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
    && uv sync --frozen --no-dev --extra browser --extra desktop \
    && python -c 'import importlib.util as u; assert u.find_spec("mss") and u.find_spec("pynput") and u.find_spec("PIL")' \
    && playwright install --with-deps chromium \
    && apt-get update \
    && apt-get install -y --no-install-recommends fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/* /tmp/* \
    && test "$(python -c 'import importlib.metadata; print(importlib.metadata.version("octop"))')" = "${OCTOP_SOURCE_VERSION}" \
    && chmod +x /usr/local/bin/octop-upstream-entrypoint /usr/local/bin/octop-hfs-entrypoint \
    && if ! getent passwd 1000 >/dev/null; then useradd --create-home --uid 1000 user; fi \
    && mkdir -p /data/.octop /home/user /opt/ms-playwright \
    && chown -R 1000:1000 /data /home/user /opt/ms-playwright

# Hugging Face runs uid 1000 without sudo. Bake the upstream virtual desktop
# into the image and chown it so the entrypoint can start Xvnc without root.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    mkdir -p /tmp/.X11-unix /tmp/runtime-octop-desktop /data/.octop/desktop; \
    chmod 1777 /tmp/.X11-unix; \
    apt-get update; \
    apt-get install -y --no-install-recommends procps; \
    if ! OCTOP_HOME=/data/.octop HOME=/data \
      /bin/bash /app/src/octop/infra/desktop/scripts/linux/v1.0/install.sh \
        --geometry "${OCTOP_DESKTOP_GEOMETRY:-1920x1080}" \
        --python /app/.venv/bin/python; then \
      echo "install.sh exited non-zero; keep baked files if the desktop stack is complete"; \
    fi; \
    pkill -f 'X(vnc|tigervnc).*:99' || true; \
    pkill -f 'openbox --config-file /opt/octop-desktop/openbox.xml' || true; \
    pkill -x xfce4-panel || true; \
    pkill -f xfdesktop || true; \
    rm -f /tmp/.X99-lock; \
    rm -rf /tmp/.X11-unix/X99 /data/.octop/desktop/pids; \
    test -x /opt/octop-desktop/start-openbox.sh; \
    test -x /opt/octop-desktop/start-session.sh; \
    test -d /etc/octop-desktop; \
    test -f /etc/octop-desktop/rfbauth; \
    command -v Xvnc >/dev/null || command -v Xtigervnc >/dev/null; \
    chown -R 1000:1000 /opt/octop-desktop /etc/octop-desktop /root /data /tmp/runtime-octop-desktop; \
    chmod 755 /root; \
    rm -rf /var/lib/apt/lists/* /tmp/*

USER 1000

EXPOSE 7860

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD ["sh", "-c", "curl -fsS http://127.0.0.1:${OCTOP_PORT:-7860}/api/health >/dev/null"]

ENTRYPOINT ["/usr/local/bin/octop-hfs-entrypoint"]
CMD []
