#!/usr/bin/env bash
# AI Code Editor — SSH port forward to Comserv dev (port 3001).
#
# Comserv login requires a configured hostname (workstation.local), not a raw IP.
# With the tunnel running, open: http://workstation.local:3001/ai/editing_widget_popup
# On the tablet, add to /etc/hosts (or equivalent):  127.0.0.1 workstation.local
#
# ZeroTier (no tunnel): http://172.30.131.126:3001/ai/editing_widget_popup
#
# One-time: ssh-copy-id -i ~/.ssh/id_ed25519.pub shanta@172.30.131.126

set -euo pipefail

HOST="${AEW_SSH_HOST:-172.30.131.126}"
USER="${AEW_SSH_USER:-shanta}"
SSH_PORT="${AEW_SSH_PORT:-22}"
APP_PORT="${AEW_APP_PORT:-3001}"
BROWSER_HOST="${AEW_BROWSER_HOST:-workstation.local}"
SSH_CONFIG_HOST="${AEW_SSH_CONFIG_HOST:-comserv-aew}"

echo "=== AI Code Editor — remote access ==="
echo ""
echo "ZeroTier (tablet on network zthnhd6k65):"
echo "  http://${HOST}:${APP_PORT}/ai/editing_widget_popup"
echo ""
echo "SSH tunnel (paste on tablet terminal):"
echo "  ssh -N -L ${APP_PORT}:127.0.0.1:${APP_PORT} -p ${SSH_PORT} ${USER}@${HOST}"
echo ""
echo "With ~/.ssh/config Host ${SSH_CONFIG_HOST}:"
echo "  ssh -N ${SSH_CONFIG_HOST}"
echo ""
echo "After tunnel — on tablet add to hosts file:"
echo "  127.0.0.1 ${BROWSER_HOST}"
echo "Then browser (required for login):"
echo "  http://${BROWSER_HOST}:${APP_PORT}/ai/editing_widget_popup"
echo ""
echo "Do NOT use http://192.168.1.199 — that IP is not in sitedomain."
echo ""

if [[ "${1:-}" == "--print-only" ]]; then
    exit 0
fi

echo "Starting tunnel (Ctrl+C to stop)…"
exec ssh -N \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -L "${APP_PORT}:127.0.0.1:${APP_PORT}" \
    -p "${SSH_PORT}" \
    "${USER}@${HOST}"