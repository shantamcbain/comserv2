#!/usr/bin/env bash
# Allow Hermes dashboard :9119 from ZeroTier (and LAN).
# Remote browsers time out when ufw blocks 9119 even though hermes is listening.
# Run on the workstation:
#   sudo bash script/open_hermes9119_for_zerotier.sh

set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

ZT_NET="${ZT_NET:-172.30.0.0/16}"
LAN_NET="${LAN_NET:-192.168.1.0/24}"
ZT_IP=$(ip -4 addr show 2>/dev/null | awk '/^[0-9]+: zt/ {getline; if ($1 ~ /inet/) {print $2; exit}}' | cut -d/ -f1 || true)
[ -z "$ZT_IP" ] && ZT_IP="172.30.131.126"

echo "=== Opening Hermes dashboard :9119 for ZeroTier ==="
if command -v ufw >/dev/null 2>&1; then
  ufw allow from "$ZT_NET" to any port 9119 proto tcp comment 'Hermes dashboard from ZeroTier' || true
  ufw allow from "$LAN_NET" to any port 9119 proto tcp comment 'Hermes dashboard from LAN' || true
  ufw status | rg '9119|Status' || ufw status numbered | head -50
else
  echo "ufw not installed"
fi

echo
echo "From a ZeroTier client open:"
echo "  http://${ZT_IP}:9119/"
echo
if ss -ltn | rg -q ':9119'; then
  echo "  hermes: listening on :9119"
else
  echo "  WARNING: nothing on :9119 — start: hermes dashboard --host 0.0.0.0 --port 9119 --no-open --skip-build"
fi
