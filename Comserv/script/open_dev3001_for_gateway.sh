#!/usr/bin/env bash
# Open workstation :3001 to the OPNsense gateway (192.168.1.1) and LAN.
# Run once on the workstation (needs your sudo password):
#   sudo script/open_dev3001_for_gateway.sh
#
# PyCharm: right-click this file → Run, or open Terminal and press Up to re-run.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

GW_NET="${GATEWAY_NET:-192.168.1.0/24}"
GW_IP="${GATEWAY_IP:-192.168.1.1}"

echo "=== Opening Comserv dev port 3001 for gateway/LAN ==="

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow from "$GW_NET" to any port 3001 proto tcp comment 'Comserv dev from LAN' || true
    ufw allow from "$GW_IP" to any port 3001 proto tcp comment 'Comserv dev from OPNsense' || true
    ufw allow 3001/tcp comment 'Comserv dev Starman' || true
    echo "  ufw: allowed 3001/tcp (LAN + gateway)"
else
    echo "  ufw: not active (skip)"
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    ZT_IF="${ZT_INTERFACE:-zthnhd6k65}"
    ZONE="${FIREWALLD_ZONE:-public}"
    if ip link show "$ZT_IF" &>/dev/null; then
        firewall-cmd --permanent --zone="$ZONE" --add-interface="$ZT_IF" 2>/dev/null \
            || firewall-cmd --permanent --zone="$ZONE" --change-interface="$ZT_IF" 2>/dev/null \
            || true
    fi
    for port in 3000 3001 7682 10000; do
        firewall-cmd --permanent --zone="$ZONE" --add-port="${port}/tcp" 2>/dev/null || true
    done
    firewall-cmd --reload
    echo "  firewalld: ports 3000/3001 open in zone ${ZONE}"
else
    echo "  firewalld: not installed (skip)"
fi

echo ""
echo "=== Quick test from this host ==="
if curl -sf --max-time 3 "http://127.0.0.1:3001/health" >/dev/null; then
    echo "  local :3001/health OK"
else
    echo "  WARNING: Starman not responding on :3001 — start dev server first"
fi

echo ""
echo "=== Next: test via gateway (no :3001 in URL) ==="
echo "  http://dev.computersystemconsulting.ca/"
echo "  (LAN DNS must use OPNsense 192.168.1.1)"
echo ""
echo "Done."