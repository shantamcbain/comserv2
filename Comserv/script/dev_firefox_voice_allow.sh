#!/usr/bin/env bash
# Legacy: Firefox HTTP allowlist for mic on raw IP:3001.
# Preferred: private HTTPS on the workstation (no allowlist needed):
#   workstation: ./script/dev_tls_install.sh
#   laptop:      ./script/dev_tls_trust_firefox.sh
#   hosts:       172.30.131.126  dev.computersystemconsulting.ca
#   open:        https://dev.computersystemconsulting.ca/ai/widget
#
# Usage: ./script/dev_firefox_voice_allow.sh
#        ./script/dev_firefox_voice_allow.sh --print

set -euo pipefail

ZT_IP="${AEW_ZEROTIER_HOST:-172.30.131.126}"
APP_PORT="${AEW_APP_PORT:-3001}"
TLS_PORT="${AEW_TLS_PORT:-3443}"

ORIGINS="http://${ZT_IP}:${APP_PORT},http://127.0.0.1:${APP_PORT},http://localhost:${APP_PORT}"
# Optional: also allow the self-signed HTTPS proxy without fighting mixed rules
ORIGINS="${ORIGINS},https://${ZT_IP}:${TLS_PORT}"

_find_profile() {
    local base
    for base in \
        "$HOME/snap/firefox/common/.mozilla/firefox" \
        "$HOME/.mozilla/firefox"
    do
        [[ -f "$base/profiles.ini" ]] || continue
        local path
        path=$(grep -E '^Path=' "$base/profiles.ini" | head -1 | cut -d= -f2-)
        [[ -n "$path" && -d "$base/$path" ]] && { echo "$base/$path"; return 0; }
    done
    return 1
}

if [[ "${1:-}" == "--print" ]]; then
    echo "Firefox about:config preference:"
    echo "  dom.securecontext.allowlist = $ORIGINS"
    echo ""
    echo "After setting, restart Firefox and open:"
    echo "  http://${ZT_IP}:${APP_PORT}/ai/widget"
    exit 0
fi

PROFILE=$(_find_profile) || {
    echo "ERROR: No Firefox profile found."
    echo "Set manually in about:config:"
    echo "  dom.securecontext.allowlist = $ORIGINS"
    exit 1
}

USER_JS="$PROFILE/user.js"
MARKER="Comserv dev voice allowlist"

if [[ -f "$USER_JS" ]] && grep -q "$MARKER" "$USER_JS" 2>/dev/null; then
    echo "Already configured in $USER_JS"
else
    cat >>"$USER_JS" <<EOF

// $MARKER — private dev server; mic allowed on HTTP (no public cert needed)
user_pref("dom.securecontext.allowlist", "$ORIGINS");
EOF
    echo "Wrote $USER_JS"
fi

echo ""
echo "Restart Firefox completely, then open:"
echo "  http://${ZT_IP}:${APP_PORT}/ai/widget"
echo ""
echo "Voice/Record should work without HTTPS or certificate warnings."
echo "(Android Firefox does not support this — use https://${ZT_IP}:${TLS_PORT} there.)"