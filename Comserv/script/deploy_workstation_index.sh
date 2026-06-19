#!/usr/bin/env bash
# Deploy workstation Apache fallback (redirect :80 → :3001 on same hostname).
# Prefer install_apache_comserv_proxy.sh so :80 proxies to Starman with Host preserved.
# PyCharm: right-click → Run, or Terminal → Up to re-run.

set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)/script/workstation_index.html"
DEST="/var/www/html/index.html"

if [[ ! -f "$SRC" ]]; then
    echo "Missing: $SRC"
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    if command -v pkexec >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
        exec pkexec bash "$0" "$@"
    fi
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

cp "$SRC" "$DEST"
chmod 644 "$DEST"
echo "Deployed $SRC → $DEST"