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
    mkdir -p /cache/tt /cache/session /tmp/comserv/cache
    chown -R comserv:comserv /cache /tmp/comserv 2>/dev/null || true
    chmod -R 755 /cache /tmp/comserv 2>/dev/null || true

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
    exec perl -Ilib script/comserv_server.pl --port "$PORT" "$@"
fi