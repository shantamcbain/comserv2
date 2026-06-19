#!/usr/bin/env bash
# Restart workstation Starman dev server (:3001). Uses fork so long AI chat does not block file ops.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

_stop_port_3001() {
    pgrep -f 'script/comserv_server.pl -p 3001' | xargs -r kill 2>/dev/null || true
    if command -v fuser >/dev/null 2>&1; then
        fuser -k 3001/tcp 2>/dev/null || true
    else
        ss -tlnp 'sport = :3001' 2>/dev/null \
            | rg -o 'pid=\d+' \
            | sed 's/pid=//' \
            | sort -u \
            | xargs -r kill 2>/dev/null || true
    fi
    sleep 2
    pgrep -f 'script/comserv_server.pl -p 3001' | xargs -r kill -9 2>/dev/null || true
    if command -v fuser >/dev/null 2>&1; then
        fuser -k 3001/tcp 2>/dev/null || true
    fi
    sleep 1
}

_stop_port_3001

export CATALYST_DEBUG=1
export CATALYST_FORCE_FORK=1
nohup perl script/comserv_server.pl -p 3001 -r -f >> logs/dev_server.log 2>&1 &

for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf -m 3 http://127.0.0.1:3001/ai/editor_config -H 'Host: dev.computersystemconsulting.ca' >/dev/null; then
        break
    fi
    sleep 1
done

if curl -sf -m 5 http://127.0.0.1:3001/ai/editor_config -H 'Host: dev.computersystemconsulting.ca' >/dev/null; then
    echo "Dev server OK on :3001 (fork enabled for parallel AI requests)"
else
    echo "Dev server started but health check failed — see logs/dev_server.log"
    exit 1
fi