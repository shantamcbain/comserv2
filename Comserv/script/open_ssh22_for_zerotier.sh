#!/usr/bin/env bash
# Open workstation SSH (port 22) to ZeroTier so remote devices can:
#   ssh shanta@172.30.131.126
# Run on the workstation (needs sudo):
#   sudo bash script/open_ssh22_for_zerotier.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

ZT_NET="${ZT_NET:-172.30.0.0/16}"
ZT_IP=$(ip -4 addr show 2>/dev/null | awk '/^[0-9]+: zt/ {getline; if ($1 ~ /inet/) {print $2; exit}}' | cut -d/ -f1 || true)
[ -z "$ZT_IP" ] && ZT_IP="172.30.131.126"

echo "=== Opening SSH :22 for ZeroTier (${ZT_NET}) ==="

if command -v ufw >/dev/null 2>&1; then
    ufw allow from "$ZT_NET" to any port 22 proto tcp comment 'SSH from ZeroTier' || true
    # optional: LAN too (home)
    ufw allow from 192.168.1.0/24 to any port 22 proto tcp comment 'SSH from LAN' || true
    echo "  ufw rules added"
    ufw status | rg '22|Status' || ufw status numbered | head -40
else
    echo "  ufw not found — add iptables/nft allow for tcp/22 from ${ZT_NET} manually"
fi

echo
echo "Test from a ZeroTier client:"
echo "  ping ${ZT_IP}"
echo "  ssh shanta@${ZT_IP}"
echo
if ss -ltn | rg -q ':22'; then
    echo "  local sshd: listening on :22"
else
    echo "  WARNING: nothing listening on :22"
fi
