#!/bin/bash
set -e

# Default values
PORT="${PORT:-3000}"
WORKERS="${WORKERS:-4}"
ENVIRONMENT="${ENVIRONMENT:-development}"

echo "=== Comserv Starting ==="
echo "Environment: $ENVIRONMENT"
echo "Port: $PORT"
echo "Workers: $WORKERS"

if [ "$ENVIRONMENT" = "production" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "→ Starting with Starman (production-grade server)"

    # Ensure cache directories are writable
    mkdir -p /cache/tt /cache/session /tmp/comserv/cache /opt/comserv/root/themes /tmp/comserv/temp /tmp/comserv/session
    # chown each directory separately so volume-mounted dirs under /tmp/comserv (e.g. session, temp) get fixed too
    chown -R comserv:comserv /cache /opt/comserv/root/themes 2>&1 || true
    for dir in /tmp/comserv /tmp/comserv/session /tmp/comserv/temp /tmp/comserv/cache; do
        if [ -d "$dir" ]; then chown comserv:comserv "$dir" 2>&1 || true; fi
    done
    chmod -R 755 /cache /tmp/comserv /opt/comserv/root/themes /tmp/comserv/temp 2>/dev/null || true

    # Use the canonical production PSGI (has Static middleware for menu CSS/JS)
    PSGI_FILE="script/comserv_server.psgi"
    if [ ! -f "$PSGI_FILE" ]; then
        echo "ERROR: $PSGI_FILE not found!"
        exit 1
    fi

    exec plackup -s Starman \
        --workers "$WORKERS" \
        --port "$PORT" \
        --access-log /dev/stdout \
        --error-log /dev/stderr \
        "$PSGI_FILE"

else
    echo "→ Starting development server (comserv_server.pl)"
    # Ensure session dir is writable (volume-mounted dirs may be root-owned)
    mkdir -p /tmp/comserv/cache /tmp/comserv/temp
    for dir in /tmp/comserv /tmp/comserv/session /tmp/comserv/temp /tmp/comserv/cache; do
        if [ -d "$dir" ]; then chown comserv:comserv "$dir" 2>&1 || true; fi
    done
    exec perl -Ilib script/comserv_server.pl --port "$PORT" "$@"
fi