#!/usr/bin/env bash
set -euo pipefail

: "${OCTOP_DEFAULT_PASSWORD:?OCTOP_DEFAULT_PASSWORD is required}"

export OCTOP_HFS_MOUNT="${OCTOP_HFS_MOUNT:-/data}"
export HOME="${HOME:-${OCTOP_HFS_MOUNT}}"
export OCTOP_HOME="${OCTOP_HOME:-${HOME}/.octop}"

if [[ "${HOME}" != "${OCTOP_HFS_MOUNT}" || "${OCTOP_HOME}" != "${HOME}/.octop" ]]; then
    echo "[storage] HOME and OCTOP_HOME must map to ${OCTOP_HFS_MOUNT} and ${OCTOP_HFS_MOUNT}/.octop" >&2
    exit 1
fi

mount_found=false
while read -r _ _ _ _ mount_point _; do
    if [[ "${mount_point}" == "${OCTOP_HFS_MOUNT}" ]]; then
        mount_found=true
        break
    fi
done < /proc/self/mountinfo
if [[ "${mount_found}" != true ]]; then
    echo "[storage] required HFS volume is not mounted at ${OCTOP_HFS_MOUNT}" >&2
    exit 1
fi

if ! mkdir -p "${OCTOP_HOME}"; then
    echo "[storage] cannot create Octop home at ${OCTOP_HOME}" >&2
    exit 1
fi

if ! probe_path="$(mktemp "${OCTOP_HOME}/.hfs-write-probe.XXXXXX")"; then
    echo "[storage] HFS volume at ${OCTOP_HFS_MOUNT} is not writable" >&2
    exit 1
fi
if ! rm "${probe_path}"; then
    echo "[storage] HFS volume write probe could not be removed: ${probe_path}" >&2
    exit 1
fi

mkdir -p \
    "${XDG_CACHE_HOME:-/tmp/octop-cache/xdg}" \
    "${UV_CACHE_DIR:-/tmp/octop-cache/uv}" \
    "${PIP_CACHE_DIR:-/tmp/octop-cache/pip}" \
    "${NPM_CONFIG_CACHE:-/tmp/octop-cache/npm}"

if command -v Xvnc >/dev/null 2>&1 || command -v Xtigervnc >/dev/null 2>&1; then
    echo "[entrypoint] refusing to start: remote desktop is disabled on Hugging Face Spaces" >&2
    exit 1
fi

echo "[storage] verified read-write HFS volume at ${OCTOP_HFS_MOUNT}; OCTOP_HOME=${OCTOP_HOME}"

exec /usr/local/bin/octop-upstream-entrypoint "$@"
