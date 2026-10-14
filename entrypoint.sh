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

# ---------------------------------------------------------------------------
# WARP (usque) egress for model traffic
# ---------------------------------------------------------------------------
# HF Spaces share egress IPs; on 2026-10-14 the shared egress to
# gateway.ai.cloudflare.com was TLS-blackholed for hours (TCP fine, TLS
# handshake dropped). Routing model egress through a local userspace WARP
# tunnel sidesteps the shared egress entirely. Design mirrored from
# CPA-HFS-2026-PRO, adapted:
#   - HTTP proxy mode (not SOCKS5): Octop's httpx stack has no socksio
#     dependency, but honors HTTPS_PROXY natively.
#   - Registration config persisted under /data so rebuilds reuse the
#     same WARP identity.
#   - Fail-open: if WARP cannot start, Octop still boots with direct
#     egress (the pre-WARP behavior).
start_warp_if_enabled() {
    if [ "${OCTOP_WARP_ENABLED:-false}" != "true" ]; then
        echo "[warp] disabled (OCTOP_WARP_ENABLED!=true); model egress stays direct"
        return 0
    fi
    if ! command -v usque >/dev/null 2>&1; then
        echo "[warp] usque binary missing; model egress stays direct" >&2
        return 0
    fi

    local warp_dir="${OCTOP_HFS_MOUNT}/warp"
    local usque_config="${warp_dir}/usque-config.json"
    mkdir -p "${warp_dir}"

    if [ ! -f "${usque_config}" ]; then
        echo "[warp] no registration found; registering a new WARP identity ..."
        if usque -c "${usque_config}" register --accept-tos >/dev/null 2>&1; then
            chmod 600 "${usque_config}"
            echo "[warp] registered; config saved to ${usque_config}"
        else
            echo "[warp] registration failed; model egress stays direct" >&2
            return 0
        fi
    fi

    local port="${OCTOP_WARP_HTTP_PORT:-8080}"
    usque -c "${usque_config}" http-proxy --bind 127.0.0.1 --port "${port}" --http2 &
    WARP_PID=$!
    echo "[warp] usque HTTP proxy started (pid=${WARP_PID}, bind=127.0.0.1:${port})"

    # Probe the tunnel (max ~10s); fail-open on timeout, the proxy process
    # may still finish handshaking after we hand off to Octop.
    local deadline=$(( $(date +%s) + 10 ))
    while [ "$(date +%s)" -lt "${deadline}" ]; do
        if curl -s -x "http://127.0.0.1:${port}" \
            --connect-timeout 2 --max-time 2 \
            https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -q 'warp='; then
            echo "[warp] tunnel verified"
            break
        fi
        sleep 1
    done

    export HTTPS_PROXY="http://127.0.0.1:${port}"
    export HTTP_PROXY="http://127.0.0.1:${port}"
    # Feishu long-lived WS, HF-internal Space-to-Space traffic, and
    # loopback must never enter the tunnel.
    export NO_PROXY="${OCTOP_WARP_NO_PROXY:-.feishu.cn,.feishu.com,.larksuite.com,.hf.space,huggingface.co,localhost,127.0.0.1}"
    echo "[warp] HTTPS_PROXY set; NO_PROXY=${NO_PROXY}"
}

WARP_PID=""
start_warp_if_enabled

python /app/verify_hfs_runtime.py --database-summary

exec /usr/local/bin/octop-upstream-entrypoint "$@"
