#!/usr/bin/env bash
# Open workstation services to laptop clients on LAN + ZeroTier.
# Run on the workstation host (needs sudo):
#   sudo script/firewalld_laptop_access.sh
#
# Fixes: laptop cannot reach :3001 (Comserv dev), :10000 (Webmin), :7682 (ttyd)
# when connecting via ZeroTier (172.30.131.126) — ZT interface often has no zone.

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

ZT_IF="${ZT_INTERFACE:-zthnhd6k65}"
ZONE="${FIREWALLD_ZONE:-public}"

echo "=== firewalld: allow laptop access (zone=${ZONE}) ==="

# ZeroTier traffic arrives on this interface; without a zone it is often dropped.
if ip link show "$ZT_IF" &>/dev/null; then
    firewall-cmd --permanent --zone="$ZONE" --add-interface="$ZT_IF" 2>/dev/null \
        || firewall-cmd --permanent --zone="$ZONE" --change-interface="$ZT_IF" 2>/dev/null \
        || true
    echo "  interface ${ZT_IF} → zone ${ZONE}"
else
    echo "  warning: ZeroTier interface ${ZT_IF} not found (skip)"
fi

for port in 3000 3001 7682 10000; do
    firewall-cmd --permanent --zone="$ZONE" --add-port="${port}/tcp" 2>/dev/null || true
    echo "  port ${port}/tcp in ${ZONE}"
done

firewall-cmd --reload

echo ""
echo "=== active zones ==="
firewall-cmd --get-active-zones
echo ""
echo "=== ${ZONE} ports (sample) ==="
firewall-cmd --zone="$ZONE" --list-ports | tr ' ' '\n' | grep -E '^(3000|3001|7682|10000)' || true
echo ""
echo "From laptop try:"
echo "  http://192.168.1.199:3001/admin/ssh_terminal   (same LAN)"
echo "  http://172.30.131.126:3001/admin/ssh_terminal (ZeroTier)"
echo "  https://172.30.131.126:10000/                  (Webmin)"
echo ""
echo "If ZeroTier still times out, use SSH tunnel: ./script/aew_ssh_tunnel.sh"