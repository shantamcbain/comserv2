#!/usr/bin/env bash
# Trust the Comserv dev CA in Firefox so https://dev.* works without warnings.
# Run on each laptop after copying comserv-dev-ca.pem from the workstation.
#
#   scp shanta@172.30.131.126:Comserv/config/dev_tls/comserv-dev-ca.pem ~/
#   ./script/dev_tls_trust_firefox.sh ~/comserv-dev-ca.pem
#
# Restart Firefox, then open https://dev.computersystemconsulting.ca/

set -euo pipefail

CA_FILE="${1:-$(cd "$(dirname "$0")/.." && pwd)/config/dev_tls/comserv-dev-ca.pem}"
CA_NICK="Comserv Dev CA"

if [[ ! -f "$CA_FILE" ]]; then
    echo "ERROR: CA file not found: $CA_FILE"
    echo "Copy from workstation: config/dev_tls/comserv-dev-ca.pem"
    exit 1
fi

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

PROFILE=$(_find_profile) || {
    echo "ERROR: No Firefox profile found."
    echo ""
    echo "Import manually: Firefox → Settings → Privacy & Security → Certificates"
    echo "  → View Certificates → Authorities → Import → $CA_FILE"
    echo "  Check 'Trust this CA to identify websites'."
    exit 1
}

if command -v certutil >/dev/null 2>&1; then
    # Remove old import if re-running
    certutil -D -n "$CA_NICK" -d "sql:$PROFILE" 2>/dev/null || true
    certutil -A -n "$CA_NICK" -t "C,," -i "$CA_FILE" -d "sql:$PROFILE"
    echo "Trusted $CA_NICK in Firefox profile:"
    echo "  $PROFILE"
else
    echo "certutil not found — import manually in Firefox:"
    echo "  Settings → Privacy & Security → Certificates → View Certificates"
    echo "  → Authorities → Import → $CA_FILE"
    echo "  Enable 'Trust this CA to identify websites'."
fi

echo ""
echo "Restart Firefox completely, then open:"
echo "  https://dev.computersystemconsulting.ca/admin"
echo ""
echo "/etc/hosts on this machine must include:"
echo "  172.30.131.126  dev.computersystemconsulting.ca dev.beemaster.ca"