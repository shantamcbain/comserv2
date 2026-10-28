#!/bin/bash
set -e

# Default values
PORT="${PORT:-3000}"
WORKERS="${WORKERS:-8}"
MAX_REQUESTS="${MAX_REQUESTS:-1000}"
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
    # NOT recursive on /tmp/comserv: the session dir can hold >1M files and a
    # recursive walk delayed startup by ~4.5 min (2026-10-18 failed deploy).
    chmod -R 755 /cache /opt/comserv/root/themes 2>/dev/null || true
    chmod 755 /tmp/comserv /tmp/comserv/temp /tmp/comserv/cache 2>/dev/null || true
    chmod 777 /tmp/comserv/session 2>/dev/null || true

    # Expired file-session cleanup (background, low priority). Sessions expire
    # after SESSION_EXPIRES_S (Plugin::Session expires / file fallback = 86400);
    # every write refreshes mtime, so a file untouched for expiry + 1h is dead.
    if [ "${SESSION_CLEANUP:-1}" = "1" ]; then
        (
            SESS_DIR="${COMSERV_SESSION_DIR:-/tmp/comserv/session}"
            AGE_MIN=$(( ${SESSION_EXPIRES_S:-86400} / 60 + 60 ))
            sleep 600
            while :; do
                if [ -d "$SESS_DIR" ]; then
                    nice -n 19 ionice -c3 find "$SESS_DIR" -maxdepth 1 -type f -mmin +"$AGE_MIN" -delete 2>/dev/null || true
                fi
                sleep "${SESSION_CLEANUP_INTERVAL_S:-3600}"
            done
        ) &
    fi

    # Use the canonical production PSGI (has Static middleware for menu CSS/JS)
    PSGI_FILE="script/comserv_server.psgi"
    if [ ! -f "$PSGI_FILE" ]; then
        echo "ERROR: $PSGI_FILE not found!"
        exit 1
    fi

    exec plackup -s Starman \
        --workers "$WORKERS" \
        --max-requests "$MAX_REQUESTS" \
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