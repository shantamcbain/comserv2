#!/bin/bash

# Startup wrapper for Comserv Starman server
# Purpose: Pre-test module loading and capture startup errors for logging

CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
PLACK_ENV="${PLACK_ENV:-deployment}"
PORT="${WEB_PORT:-3000}"
WORKERS="${STARMAN_WORKERS:-2}"

set -u

echo "========================================"
echo "Starting Comserv Starman Server"
echo "========================================"
echo "CATALYST_HOME: $CATALYST_HOME"
echo "PLACK_ENV: $PLACK_ENV"
echo "PORT: $PORT"
echo "WORKERS: $WORKERS"
echo "PERL5LIB: $PERL5LIB"
echo "PATH: $PATH"
echo "========================================"

# Pre-flight check: Verify Catalyst loads
echo "[startup-wrapper] Pre-flight: Testing Perl module loading..."
if perl -e 'use Comserv; print "✓ Comserv module loads successfully\n"' 2>&1; then
  echo "[startup-wrapper] ✓ Module loading successful"
else
  echo "[startup-wrapper] ✗ FATAL: Failed to load Comserv module" >&2
  echo "[startup-wrapper] Error details above" >&2
  exit 2
fi

# Pre-flight check: Test PSGI app
echo "[startup-wrapper] Pre-flight: Testing PSGI app..."
if perl -e "use lib '$CATALYST_HOME/lib'; use Comserv; my \$app = Comserv->psgi_app; print \"✓ PSGI app loads successfully\n\"" 2>&1; then
  echo "[startup-wrapper] ✓ PSGI app loaded successfully"
else
  echo "[startup-wrapper] ✗ FATAL: Failed to load PSGI app" >&2
  echo "[startup-wrapper] Error details above" >&2
  exit 2
fi

# All checks passed, run Starman
echo "[startup-wrapper] Starting Starman server..."
echo "========================================"

exec perl -S starman \
  --env "$PLACK_ENV" \
  --listen ":$PORT" \
  --host 0.0.0.0 \
  --workers "$WORKERS" \
  "$CATALYST_HOME/script/comserv_server.psgi"
