#!/usr/bin/env bash
# Writable Comserv ttyd (no sudo) — bash login shell on 0.0.0.0:7682 (LAN + localhost)
# Base path /admin/ttyd-proxy is proxied through Comserv (port 3000) for remote browsers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR="$ROOT/var"
PIDFILE="$VAR/ttyd-comserv.pid"
SOCK_PIDFILE="$VAR/ttyd-proxy.pid"
LOG="$VAR/ttyd-comserv.log"
PORT=7682
BASE_PATH="/admin/ttyd-proxy"
SOCK="$VAR/ttyd-proxy.sock"

mkdir -p "$VAR"

_ttyd_running_ok() {
    local _line="$1"
    echo "$_line" | grep -qE '(^|[[:space:]])-W($|[[:space:]])' \
        && echo "$_line" | grep -qE '(^|[[:space:]])-i[[:space:]]+0\.0\.0\.0' \
        && echo "$_line" | grep -qF -- "-b ${BASE_PATH}"
}

if pgrep -f "ttyd.*-p ${PORT}" >/dev/null 2>&1; then
    _line="$(pgrep -af "ttyd.*-p ${PORT}" | head -1 || true)"
    if _ttyd_running_ok "$_line"; then
        echo "Writable LAN ttyd already running on port ${PORT} (base-path ${BASE_PATH})"
        echo "$_line"
    else
        if echo "$_line" | grep -qE '(^|[[:space:]])-i[[:space:]]+127\.0\.0\.1'; then
            echo "Restarting localhost-only ttyd on port ${PORT}…"
        else
            echo "Restarting ttyd on port ${PORT} (missing -W, 0.0.0.0 bind, or base-path)…"
        fi
        pkill -f "ttyd.*-p ${PORT}" || true
        sleep 1
    fi
fi

if ! pgrep -f "ttyd.*-p ${PORT}" >/dev/null 2>&1; then
    nohup /usr/bin/ttyd -i 0.0.0.0 -p "$PORT" -b "$BASE_PATH" -P 5 -w /home/shanta -W bash -l >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    sleep 1
fi

if command -v socat >/dev/null 2>&1; then
    if ! pgrep -f "socat.*ttyd-proxy.sock" >/dev/null 2>&1; then
        rm -f "$SOCK"
        nohup socat UNIX-LISTEN:"${SOCK}",fork,reuseaddr,unlink-early TCP:127.0.0.1:${PORT} >>"$LOG" 2>&1 &
        echo $! >"$SOCK_PIDFILE"
        sleep 0.5
    fi
else
    echo "Warning: socat not installed — Docker dev cannot reach host ttyd (install socat)" >&2
fi

if curl -sf -o /dev/null "http://127.0.0.1:${PORT}${BASE_PATH}/"; then
    echo "Started writable ttyd on port ${PORT} (proxy via ${BASE_PATH} on Comserv port 3000)"
else
    echo "ttyd failed to start — see $LOG" >&2
    exit 1
fi