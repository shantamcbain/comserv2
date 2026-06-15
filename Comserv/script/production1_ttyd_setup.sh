#!/usr/bin/env bash
# One-time / ongoing setup on production1 (192.168.1.126) for /admin/ssh_terminal.
# Run on the production1 HOST as the user that runs Comserv/ttyd (e.g. ubuntu or shanta).
#
#   cd /opt/comserv/Comserv && script/production1_ttyd_setup.sh
#
# Requires: deployed Comserv image with ssh_terminal + ttyd-proxy routes, and
# docker-compose.server.yml var/ mount (see script/docker-compose.server.yml).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== production1 ttyd setup ==="

mkdir -p var

if ! command -v ttyd >/dev/null 2>&1; then
    echo "Install ttyd on this host first, e.g.: sudo apt install ttyd" >&2
    exit 1
fi

if ! command -v socat >/dev/null 2>&1; then
    echo "Install socat for Docker→host bridge, e.g.: sudo apt install socat" >&2
    exit 1
fi

script/ttyd_comserv_start.sh

if [[ ! -S var/ttyd-proxy.sock ]]; then
    echo "ttyd-proxy.sock missing — check var/ttyd-comserv.log" >&2
    exit 1
fi

echo ""
echo "Started. Verify on host:"
echo "  curl -sf http://127.0.0.1:7682/admin/ttyd-proxy/ >/dev/null && echo OK"
echo ""
echo "After Comserv deploy, verify in browser (admin login):"
echo "  https://computersystemconsulting.ca/admin/ssh_terminal"
echo ""
echo "Keep script/ttyd_host_watcher.sh running on this host for Start ttyd from the UI."