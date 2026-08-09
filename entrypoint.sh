#!/usr/bin/env bash
set -euo pipefail

: "${OCTOP_DEFAULT_PASSWORD:?OCTOP_DEFAULT_PASSWORD is required}"

exec /usr/local/bin/octop-upstream-entrypoint "$@"
