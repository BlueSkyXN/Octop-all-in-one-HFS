#!/usr/bin/env bash
set -euo pipefail

: "${OCTOP_DEFAULT_PASSWORD:?OCTOP_DEFAULT_PASSWORD is required}"

export HOME="${HOME:-/data}"
export OCTOP_HOME="${OCTOP_HOME:-${HOME}/.octop}"
export DISPLAY="${DISPLAY:-:99}"
export OCTOP_DESKTOP_DISPLAY="${OCTOP_DESKTOP_DISPLAY:-:99}"
export OCTOP_DESKTOP_GEOMETRY="${OCTOP_DESKTOP_GEOMETRY:-1920x1080}"

mkdir -p "${OCTOP_HOME}/desktop" /tmp/.X11-unix /tmp/runtime-octop-desktop
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

if [ ! -f "${OCTOP_HOME}/desktop/desktop.env" ]; then
    cat > "${OCTOP_HOME}/desktop/desktop.env" << EOF
export DISPLAY=${DISPLAY}
export OCTOP_DESKTOP_DISPLAY=${OCTOP_DESKTOP_DISPLAY}
export OCTOP_DESKTOP_GEOMETRY=${OCTOP_DESKTOP_GEOMETRY}
EOF
fi

start_script="$(python -c 'from octop.infra.desktop.setup import bundled_scripts_dir; print(bundled_scripts_dir() / "start.sh")' 2>/dev/null || true)"
if [ -n "${start_script}" ] && [ -f "${start_script}" ]; then
    if ! /bin/bash "${start_script}"; then
        echo "[entrypoint] virtual desktop start failed; Octop will continue without it" >&2
    fi
else
    echo "[entrypoint] desktop start script not found; skipping virtual desktop" >&2
fi

exec /usr/local/bin/octop-upstream-entrypoint "$@"
