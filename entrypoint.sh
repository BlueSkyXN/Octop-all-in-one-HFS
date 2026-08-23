#!/usr/bin/env bash
set -euo pipefail

: "${OCTOP_DEFAULT_PASSWORD:?OCTOP_DEFAULT_PASSWORD is required}"

export HOME="${HOME:-/data}"
export OCTOP_HOME="${OCTOP_HOME:-${HOME}/.octop}"

exec /usr/local/bin/octop-upstream-entrypoint "$@"
