#!/bin/bash
set -e
[ -n "$DB_HOST" ] && echo "Database configuration detected"

# Use environment variable with fallback for safety
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}

# Clean up stale supervisor socket and pid files
rm -f /var/run/supervisor.sock /var/run/supervisord.pid

# Ensure log directories exist and are writable
mkdir -p ${CATALYST_HOME}/root/log /var/log/supervisor
chmod 755 ${CATALYST_HOME}/root/log /var/log/supervisor

# Generate supervisor config with dynamic port
bash ${CATALYST_HOME}/create-supervisor-config.sh

# Log the port configuration
PORT=${WEB_PORT:-3000}
echo "Starting Comserv with WEB_PORT=$PORT, CATALYST_ENV=${CATALYST_ENV:-production}, DEBUG=${CATALYST_DEBUG:-0}"

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
