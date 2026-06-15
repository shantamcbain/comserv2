#!/usr/bin/env bash
# HTTPS proxy for Comserv dev so the browser allows microphone on 172.30.131.126
# (Browsers block getUserMedia on plain http:// except localhost.)
#
# Prereq: Comserv already running on 127.0.0.1:3001 (./script/start_with_websockets.sh)
#
# Usage:
#   ./script/dev_voice_https.sh          # start TLS proxy on 3443
#   ./script/dev_voice_https.sh --print  # show URLs only
#
# Then open (accept browser certificate warning once):
#   https://172.30.131.126:3443/ai/widget
#
# One-time on workstation:
#   perl script/aew_add_dev_domains.pl   # 172.30.131.126 in sitedomain

set -euo pipefail

ZT_IP="${AEW_ZEROTIER_HOST:-172.30.131.126}"
APP_PORT="${AEW_APP_PORT:-3001}"
TLS_PORT="${AEW_TLS_PORT:-3443}"
CERT_DIR="${AEW_TLS_CERT_DIR:-$(dirname "$0")/../config/dev_tls}"
CERT="$CERT_DIR/dev-${ZT_IP}.pem"
KEY="$CERT_DIR/dev-${ZT_IP}.key"

_print_urls() {
    echo ""
    echo "Voice-enabled URLs (HTTPS — mic works in browser):"
    echo "  https://${ZT_IP}:${TLS_PORT}/ai/widget"
    echo "  https://${ZT_IP}:${TLS_PORT}/ai/editing_widget_popup"
    echo ""
    echo "Comserv must be running: http://127.0.0.1:${APP_PORT}/"
    echo "First visit: accept the self-signed certificate warning in Chrome/Firefox."
    echo ""
}

if [[ "${1:-}" == "--print" ]]; then
    _print_urls
    exit 0
fi

mkdir -p "$CERT_DIR"
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    echo "Generating self-signed certificate for ${ZT_IP} ..."
    openssl req -x509 -newkey rsa:2048 -days 825 -nodes \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=${ZT_IP}" \
        -addext "subjectAltName=IP:${ZT_IP},DNS:workstation.zero,DNS:workstation.local"
    chmod 600 "$KEY"
fi

if ! curl -s -o /dev/null --connect-timeout 2 "http://127.0.0.1:${APP_PORT}/"; then
    echo "ERROR: Nothing listening on 127.0.0.1:${APP_PORT}"
    echo "Start Comserv first: ./script/start_with_websockets.sh ${APP_PORT}"
    exit 1
fi

_print_urls
echo "Starting TLS proxy ${TLS_PORT} → 127.0.0.1:${APP_PORT} (Ctrl+C to stop)..."
exec socat \
    "OPENSSL-LISTEN:${TLS_PORT},reuseaddr,fork,cert=${CERT},key=${KEY},verify=0" \
    "TCP:127.0.0.1:${APP_PORT}"