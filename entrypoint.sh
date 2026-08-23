#!/usr/bin/env bash
set -euo pipefail

: "${OCTOP_DEFAULT_PASSWORD:?OCTOP_DEFAULT_PASSWORD is required}"

export HOME="${HOME:-/data}"
export OCTOP_HOME="${OCTOP_HOME:-${HOME}/.octop}"

if command -v Xvnc >/dev/null 2>&1 || command -v Xtigervnc >/dev/null 2>&1; then
    echo "[entrypoint] refusing to start: remote desktop is disabled on Hugging Face Spaces" >&2
    exit 1
fi

exec /usr/local/bin/octop-upstream-entrypoint "$@"
