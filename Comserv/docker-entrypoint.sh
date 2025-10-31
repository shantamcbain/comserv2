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

# Create base supervisord.conf if missing or empty
if [ ! -s /etc/supervisor/supervisord.conf ]; then
    mkdir -p /etc/supervisor/conf.d
    cat > /etc/supervisor/supervisord.conf << 'EOFBASE'
[unix_http_server]
file=/var/run/supervisor.sock

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
nodaemon=true
user=root

[include]
files=/etc/supervisor/conf.d/*.conf
EOFBASE
fi

# Generate supervisor config with dynamic port
bash ${CATALYST_HOME}/create-supervisor-config.sh

# Log the port configuration
PORT=${WEB_PORT:-3000}
echo "Starting Comserv with WEB_PORT=$PORT, CATALYST_ENV=${CATALYST_ENV:-production}, DEBUG=${CATALYST_DEBUG:-0}"

exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
