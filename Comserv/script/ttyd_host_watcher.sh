#!/usr/bin/env bash
# Run on the workstation HOST (not in Docker). Watches var/ttyd-start.request
# and runs ttyd_comserv_start.sh when the Docker dev app requests a start.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VAR="$ROOT/var"
REQ="$VAR/ttyd-start.request"
PIDFILE="$VAR/ttyd-host-watcher.pid"
LOG="$VAR/ttyd-host-watcher.log"
STARTER="$ROOT/script/ttyd_comserv_start.sh"

mkdir -p "$VAR"

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "ttyd host watcher already running (pid $(cat "$PIDFILE"))"
    exit 0
fi

(
    echo "[$(date -Iseconds)] ttyd host watcher started"
    while true; do
        if [[ -f "$REQ" ]]; then
            echo "[$(date -Iseconds)] start request detected"
            rm -f "$REQ"
            if [[ -x "$STARTER" ]]; then
                "$STARTER" >>"$LOG" 2>&1 || true
            else
                echo "[$(date -Iseconds)] starter missing: $STARTER" >>"$LOG"
            fi
        fi
        sleep 2
    done
) >>"$LOG" 2>&1 &

echo $! >"$PIDFILE"
echo "ttyd host watcher started (pid $(cat "$PIDFILE"), log $LOG)"