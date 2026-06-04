#!/bin/bash

# Startup wrapper for Comserv Starman server

CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
PLACK_ENV="${PLACK_ENV:-${CATALYST_ENV:-deployment}}"
PORT="${WEB_PORT:-5000}"
WORKERS="${STARMAN_WORKERS:-5}"

set -u

echo "========================================"
echo "Starting Comserv Starman Server"
echo "  CATALYST_HOME : $CATALYST_HOME"
echo "  PLACK_ENV     : $PLACK_ENV"
echo "  PORT          : $PORT"
echo "  WORKERS       : $WORKERS"
echo "========================================"

echo "[startup-wrapper] Running pre-flight checks..."

# 1. Verify CATALYST_HOME directory
if [ -d "$CATALYST_HOME" ]; then
  echo "[startup-wrapper] ✓ CATALYST_HOME exists: $CATALYST_HOME"
else
  echo "[startup-wrapper] ✗ ERROR: CATALYST_HOME directory does not exist: $CATALYST_HOME"
  exit 1
fi

# 2. Locate and verify PSGI file
PSGI_FILE="${CATALYST_HOME}/script/comserv_server.psgi"
if [ ! -f "$PSGI_FILE" ] && [ -f "${CATALYST_HOME}/comserv_server.psgi" ]; then
  echo "[startup-wrapper] ℹ PSGI script not in script/ - found in root directory instead"
  PSGI_FILE="${CATALYST_HOME}/comserv_server.psgi"
fi

if [ -f "$PSGI_FILE" ]; then
  echo "[startup-wrapper] ✓ PSGI entrypoint verified at: $PSGI_FILE"
else
  echo "[startup-wrapper] ✗ ERROR: PSGI entrypoint not found at ${CATALYST_HOME}/script/comserv_server.psgi or ${CATALYST_HOME}/comserv_server.psgi"
  exit 1
fi

# 3. Check database port reachability (dry-run connectivity check)
if [ -n "${DB_HOST:-}" ]; then
  DB_PORT_NUM="${DB_PORT:-3306}"
  echo "[startup-wrapper] Pre-flight: Verifying connectivity to database ${DB_HOST}:${DB_PORT_NUM}..."
  if timeout 3 bash -c "echo >/dev/tcp/$DB_HOST/$DB_PORT_NUM" &>/dev/null; then
    echo "[startup-wrapper] ✓ Database port $DB_PORT_NUM is reachable"
  else
    echo "[startup-wrapper] ⚠ Warning: Database port $DB_PORT_NUM is unreachable. The application may fail to start or connect."
  fi
fi

# 4. Perform syntax & compile check to catch compilation issues and missing modules early
echo "[startup-wrapper] Pre-flight: Running Perl syntax and dependency compilation check..."
if perl -I"$CATALYST_HOME/lib" -c "$PSGI_FILE" 2>&1 | tee /tmp/psgi_compile_check.log; then
  echo "[startup-wrapper] ✓ Perl syntax and module dependency compilation check passed successfully!"
else
  echo "[startup-wrapper] ✗ ERROR: Perl compilation/syntax check failed! The application cannot load."
  echo "[startup-wrapper] Detailed compilation errors:"
  cat /tmp/psgi_compile_check.log
  exit 1
fi

if [ "$PLACK_ENV" = "development" ]; then
  echo "[startup-wrapper] Development mode — using plackup with auto-restart on file change"
  exec perl -I"$CATALYST_HOME/lib" -S plackup \
    --host 0.0.0.0 \
    --port "$PORT" \
    --reload \
    --watch "$CATALYST_HOME/lib" \
    --watch "$CATALYST_HOME/root" \
    --watch "$CATALYST_HOME/config" \
    "$PSGI_FILE"
else
  echo "[startup-wrapper] Production mode — starting Starman on :$PORT with $WORKERS workers"
  exec perl -S starman \
    --env "$PLACK_ENV" \
    --listen "0.0.0.0:$PORT" \
    --workers "$WORKERS" \
    --max-requests 1000 \
    --max-requests-jitter 100 \
    "$PSGI_FILE"
fi
