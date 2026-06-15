#!/usr/bin/env bash
# Android / remote phone access to Comserv dev (:3001) when ZeroTier HTTP fails.
#
# The workstation listens on 0.0.0.0:3001 and has ZT IP 172.30.131.126 (network zthnhd6k65).
# If the phone shows "active" in ZeroTier but cannot open http://172.30.131.126:3001,
# use one of the workarounds below.
#
# Usage:
#   ./script/aew_android_access.sh              # print all options
#   ./script/aew_android_access.sh --tunnel     # start SSH tunnel (from laptop on ZT/LAN)
#   ./script/aew_android_access.sh --cf-tunnel  # try Cloudflare quick tunnel (needs cloudflared)

set -euo pipefail

HOST="${AEW_SSH_HOST:-172.30.131.126}"
USER="${AEW_SSH_USER:-shanta}"
SSH_PORT="${AEW_SSH_PORT:-22}"
APP_PORT="${AEW_APP_PORT:-3001}"
LAN_IP="${AEW_LAN_IP:-192.168.1.199}"
ZT_NET="zthnhd6k65"

WIDGET="/ai/widget"
EDITOR="/ai/editing_widget_popup"

_print_header() {
    echo "=== Comserv dev — Android / phone access workarounds ==="
    echo ""
    echo "Workstation ZT: ${HOST}  (network ${ZT_NET})"
    echo "Dev port: ${APP_PORT}"
    echo ""
}

_print_diag() {
    echo "--- 1. Quick checks on the phone ---"
    echo "  • ZeroTier app → open network ${ZT_NET} → confirm phone has a 172.30.x.x address"
    echo "  • Phone IP must NOT be 0.0.0.0 or 'REQUESTING CONFIGURATION'"
    echo "  • In Chrome try: http://${HOST}:${APP_PORT}${WIDGET}"
    echo "  • If that times out but ZT shows connected, ZT ACL or UDP 9993 may be blocked"
    echo "    (common on mobile data — try home Wi‑Fi, or use SSH tunnel below)"
    echo ""
    echo "--- 2. One-time on workstation (site login by IP/hostname) ---"
    echo "  perl script/aew_add_dev_domains.pl"
    echo "  (adds ${HOST}, ${LAN_IP}, 127.0.0.1 to sitedomain for dev login)"
    echo ""
}

_print_lan() {
    echo "--- 3. Same Wi‑Fi (no ZeroTier) ---"
    echo "  If the phone is on the same LAN as the workstation:"
    echo "    http://${LAN_IP}:${APP_PORT}${WIDGET}"
    echo "  Requires aew_add_dev_domains.pl run once on the workstation."
    echo ""
}

_print_ssh_android() {
    echo "--- 4. SSH tunnel from Android (Termius / JuiceSSH) — best ZT workaround ---"
    echo "  Often works when raw :${APP_PORT} HTTP is blocked but SSH :${SSH_PORT} is allowed."
    echo ""
    echo "  Termius setup:"
    echo "    Host: ${HOST}   User: ${USER}   Port: ${SSH_PORT}"
    echo "    Port forwarding → Local ${APP_PORT} → Remote 127.0.0.1:${APP_PORT}"
    echo "    Start the session (keep it open)"
    echo ""
    echo "  Then on the phone browser (after aew_add_dev_domains.pl added 127.0.0.1):"
    echo "    http://127.0.0.1:${APP_PORT}${WIDGET}"
    echo ""
    echo "  Alternative hostname (needs hosts override app, or rooted /etc/hosts):"
    echo "    127.0.0.1 workstation.local"
    echo "    http://workstation.local:${APP_PORT}${WIDGET}"
    echo ""
}

_print_laptop_tunnel() {
    echo "--- 5. SSH tunnel from laptop/tablet (existing flow) ---"
    echo "  ./script/aew_ssh_tunnel.sh"
    echo "  Browser: http://workstation.local:${APP_PORT}${WIDGET}"
    echo "  (add 127.0.0.1 workstation.local to hosts file on that device)"
    echo ""
}

_print_production() {
    echo "--- 6. Test on production / hosted site (no dev IP needed) ---"
    echo "  Deploy the widget JS/CSS changes to a site the phone already reaches,"
    echo "  then open: https://YOUR-SITE/ai/widget"
    echo "  (e.g. a hosted BMaster / CSC site — microphone needs HTTPS on mobile)"
    echo ""
    echo "  Note: zero.computersystemconsulting.ca → production :5000, NOT this dev box."
    echo ""
}

_print_cf() {
    echo "--- 7. Cloudflare quick tunnel (works over any network) ---"
    echo "  On the workstation:"
    echo "    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared"
    echo "    chmod +x /tmp/cloudflared"
    echo "    /tmp/cloudflared tunnel --url http://127.0.0.1:${APP_PORT}"
    echo "  Open the printed https://*.trycloudflare.com URL on the phone + ${WIDGET}"
    echo "  Add that hostname to sitedomain (Admin → sites) before login will work."
    echo ""
}

_run_cf_tunnel() {
    local cf=""
    for c in cloudflared /tmp/cloudflared "$HOME/.local/bin/cloudflared"; do
        if [[ -x "$c" ]]; then cf="$c"; break; fi
    done
    if [[ -z "$cf" ]]; then
        echo "cloudflared not found. Install it, then re-run: $0 --cf-tunnel"
        _print_cf
        exit 1
    fi
    echo "Starting Cloudflare quick tunnel to 127.0.0.1:${APP_PORT} …"
    echo "Open the https URL below on your phone, then append ${WIDGET}"
    exec "$cf" tunnel --url "http://127.0.0.1:${APP_PORT}"
}

_run_ssh_tunnel() {
    exec "$(dirname "$0")/aew_ssh_tunnel.sh"
}

case "${1:-}" in
    --tunnel)    _run_ssh_tunnel ;;
    --cf-tunnel) _run_cf_tunnel ;;
    --print-only|'')
        _print_header
        _print_diag
        _print_lan
        _print_ssh_android
        _print_laptop_tunnel
        _print_production
        _print_cf
        ;;
    -h|--help)
        echo "Usage: $0 [--tunnel | --cf-tunnel | --print-only]"
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
esac