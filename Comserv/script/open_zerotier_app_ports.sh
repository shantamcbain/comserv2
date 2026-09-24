#!/usr/bin/env bash
# Allow remote ZeroTier (+ LAN) access to CSC / Hermes app ports on the workstation.
# Run: sudo bash /home/shanta/open-zerotier-app-ports.sh
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

ZT_NET="${ZT_NET:-172.30.0.0/16}"
LAN_NET="${LAN_NET:-192.168.0.0/16}"

# Exact ports + ranges Shanta asked for (plus SSH/Webmin so remote admin works)
PORTS=(
  22          # SSH
  3000 3001
  5000
  9119        # Hermes dashboard
  10000       # Webmin (browser terminal path)
)
# 4000-4020 inclusive
for p in $(seq 4000 4020); do PORTS+=("$p"); done

echo "=== Opening TCP ports for ZeroTier ${ZT_NET} and LAN ${LAN_NET} ==="
if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw not installed" >&2
  exit 1
fi

ufw status | head -5 || true

for p in "${PORTS[@]}"; do
  ufw allow from "$ZT_NET" to any port "$p" proto tcp comment "ZT app port $p" || true
  ufw allow from "$LAN_NET" to any port "$p" proto tcp comment "LAN app port $p" || true
done

echo
echo "=== Relevant ufw rules ==="
ufw status numbered | rg '22|3000|3001|400[0-9]|401[0-9]|4020|5000|9119|10000|Status' || ufw status numbered | head -80

echo
echo "=== Listening now ==="
ss -ltn | rg ':(22|3000|3001|400[0-9]|401[0-9]|4020|5000|9119|10000)\b' || true

echo
echo "From a ZeroTier client try:"
echo "  http://workstation.zero:3001/   or  http://172.30.131.126:3001/"
echo "  http://workstation.zero:4006/   http://workstation.zero:5000/   http://workstation.zero:9119/"
echo "  ssh shanta@workstation.zero"
