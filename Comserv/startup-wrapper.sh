#!/bin/bash

# Startup wrapper for Comserv Starman server

CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
PLACK_ENV="${PLACK_ENV:-${CATALYST_ENV:-deployment}}"
PORT="${WEB_PORT:-3000}"
WORKERS="${STARMAN_WORKERS:-5}"

set -u

echo "========================================"
echo "Starting Comserv Starman Server"
echo "  CATALYST_HOME : $CATALYST_HOME"
echo "  PLACK_ENV     : $PLACK_ENV"
echo "  PORT          : $PORT"
echo "  WORKERS       : $WORKERS"
echo "========================================"

if [ "$PLACK_ENV" = "development" ]; then
  echo "[startup-wrapper] Development mode — using plackup with auto-restart on file change"
  exec perl -I"$CATALYST_HOME/lib" -S plackup \
    --host 0.0.0.0 \
    --port "$PORT" \
    --reload \
    --watch "$CATALYST_HOME/lib" \
    --watch "$CATALYST_HOME/root" \
    --watch "$CATALYST_HOME/config" \
    "$CATALYST_HOME/script/comserv_server.psgi"
else
  echo "[startup-wrapper] Production mode — starting Starman on :$PORT with $WORKERS workers"
  exec perl -S starman \
    --env "$PLACK_ENV" \
    --listen ":$PORT" \
    --host 0.0.0.0 \
    --workers "$WORKERS" \
    --max-requests 1000 \
    --max-requests-jitter 100 \
    "$CATALYST_HOME/script/comserv_server.psgi"
fi
