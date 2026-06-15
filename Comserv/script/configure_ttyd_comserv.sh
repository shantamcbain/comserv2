#!/usr/bin/env bash
# Configure ttyd for Comserv admin terminal (writable shell, no check-origin).
set -euo pipefail

DEFAULTS_FILE=/etc/default/ttyd
RECOMMENDED='TTYD_OPTIONS="-i lo -p 7681 -c shanta -w /home/shanta -W bash -l"'

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run with sudo: sudo $0" >&2
    exit 1
fi

backup="${DEFAULTS_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$DEFAULTS_FILE" "$backup"
echo "$RECOMMENDED" > "$DEFAULTS_FILE"
echo "Updated $DEFAULTS_FILE (backup: $backup)"
echo "  -W        allow keyboard input (ttyd is read-only without this)"
echo "  no -O     allow WebSocket from the Comserv page origin"
echo "  bash -l   login shell as shanta (not system 'login' prompt)"

systemctl restart ttyd
systemctl --no-pager --full status ttyd | head -15