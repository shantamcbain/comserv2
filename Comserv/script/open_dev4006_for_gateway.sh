#!/usr/bin/env bash
# Open workstation :4006 (AI2 / aisystem) to LAN, OPNsense gateway, and ZeroTier.
# Run once on the workstation (needs sudo):
#   sudo script/open_dev4006_for_gateway.sh
#
# Lets Grok Bot (and LAN) reach http://workstation.local:4006 after ZeroTier
# or LAN routing is in place.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

GW_NET="${GATEWAY_NET:-192.168.1.0/24}"
GW_IP="${GATEWAY_IP:-192.168.1.1}"
ZT_NET="${ZT_NET:-172.30.0.0/16}"

# Detect current ZeroTier IP (for box instructions and hints)
ZT_IP=$(ip -4 addr show 2>/dev/null | awk '/^[0-9]+: zt/ {iface=$2; getline; if ($1 ~ /inet/) {print $2; exit}}' | cut -d/ -f1 || true)
[ -z "$ZT_IP" ] && ZT_IP="172.30.131.126"

echo "=== Opening Comserv AI editor port 4006 for gateway/LAN/ZeroTier ==="

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow from "$GW_NET" to any port 4006 proto tcp comment 'AI2 editor from LAN' || true
    ufw allow from "$GW_IP" to any port 4006 proto tcp comment 'AI2 editor from OPNsense' || true
    ufw allow from "$ZT_NET" to any port 4006 proto tcp comment 'AI2 editor from ZeroTier' || true
    ufw allow 4006/tcp comment 'AI2 editor aisystem' || true
    echo "  ufw: allowed 4006/tcp (LAN + gateway + ZeroTier)"
    ufw status | rg '4006|Status' || ufw status | head -20
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
    firewall-cmd --permanent --zone="$ZONE" --add-port=4006/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo "  firewalld: port 4006/tcp open in zone ${ZONE}"
else
    echo "  firewalld: not installed (skip)"
fi

echo ""
echo "=== Quick test from this host ==="
if curl -sf --max-time 3 "http://127.0.0.1:4006/" >/dev/null; then
    echo "  local :4006 OK"
else
    echo "  WARNING: nothing responding on :4006 — start aisystem server first"
fi

echo ""
echo "=== Reachability hints ==="
echo "  LAN:        http://workstation.local:4006/"
echo "  ZeroTier:  http://workstation.local:4006/  (current ZT IP: ${ZT_IP})"
echo "  (or direct: http://${ZT_IP}:4006/ or edit.computersystemconsulting.ca:4006)"
echo ""
echo "=== For Grok Bot (CSC developer box) on ZeroTier af78bf943680bfeb ==="
echo "  1. Authorize the box member in ZeroTier Central *using the API* (not web UI)."
echo "  2. On the box, ensure /etc/hosts (or DNS) resolves:"
echo "       ${ZT_IP} workstation.local"
echo "  3. Test reachability with hostname (required for app login/sitedomain/allowlist; raw IP will not work for browser login):"
echo "       curl -sS -o /dev/null -w '%{http_code}' -H 'Host: workstation.local' http://workstation.local:4006/"
echo "  4. Browser on box: http://workstation.local:4006/  (then /ai2/editing_widget_popup after login as shanta)"
echo ""
echo "Authorize new ZeroTier members in ZeroTier Central for network af78bf943680bfeb"
echo ""
echo "Done."
