#!/usr/bin/env bash
# Apache :80 → Starman :3001 so dev hostnames (dev.somedomain.name) resolve SiteName correctly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/script/apache_comserv_dev.conf"
DEST="/etc/apache2/sites-available/comserv-dev.conf"
ENABLED="/etc/apache2/sites-enabled/comserv-dev.conf"
DEFAULT="/etc/apache2/sites-enabled/000-default.conf"

if [[ ! -f "$SRC" ]]; then
    echo "Missing: $SRC"
    exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
    if command -v pkexec >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
        exec pkexec bash "$0" "$@"
    fi
    exec sudo bash "$0" "$@"
fi

a2enmod proxy proxy_http headers >/dev/null
cp "$SRC" "$DEST"
a2ensite comserv-dev.conf >/dev/null

# HTTPS uses private CA — run dev_tls_install.sh for :443 (ZeroTier dev.* + mic)
if [[ -f "$ROOT/config/dev_tls/comserv-dev.pem" && -f "$ROOT/config/dev_tls/comserv-dev-ca.pem" ]]; then
    a2enmod ssl >/dev/null 2>&1 || true
    SSL_SNIP="/etc/apache2/conf-available/comserv-dev-ssl-paths.conf"
    cat >"$SSL_SNIP" <<EOF
SSLCertificateFile    $ROOT/config/dev_tls/comserv-dev.pem
SSLCertificateKeyFile $ROOT/config/dev_tls/comserv-dev.key
SSLCertificateChainFile $ROOT/config/dev_tls/comserv-dev-ca.pem
EOF
    a2enconf comserv-dev-ssl-paths >/dev/null 2>&1 || true
fi
if [[ -e "$DEFAULT" ]]; then
    a2dissite 000-default.conf >/dev/null || true
fi
apache2ctl configtest
systemctl reload apache2
echo "Apache :80 now proxies to Starman :3001 (Host header preserved for SiteName)."
echo "Open http://dev.yourdomain.name/ — no :3001, no IP in the URL."