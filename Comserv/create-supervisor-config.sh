#!/bin/bash
set -e

PORT=${WEB_PORT:-3000}
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
CATALYST_ENV=${CATALYST_ENV:-production}
CATALYST_DEBUG=${CATALYST_DEBUG:-0}

echo "[supervisor-config] Configuring Starman with WEB_PORT=$PORT, CATALYST_ENV=$CATALYST_ENV, DEBUG=$CATALYST_DEBUG"

# Map Catalyst env to Plack/Starman
PLACK_ENV="deployment"
if [ "$CATALYST_ENV" = "development" ]; then
    PLACK_ENV="development"
fi

# Number of workers based on environment
WORKERS=${STARMAN_WORKERS:-2}
if [ "$CATALYST_ENV" = "development" ]; then
    WORKERS=1
fi

# Use perl -S to execute starman with the container's Perl interpreter
# This avoids shebang issues when scripts are built with different Perl paths
if command -v starman >/dev/null 2>&1; then
  START_CMD="perl -S starman --env $PLACK_ENV --listen :$PORT --host 0.0.0.0 --workers $WORKERS ${CATALYST_HOME}/script/comserv_server.psgi"
  echo "[supervisor-config] Using 'perl -S starman' (avoids shebang path issues)"
else
  START_CMD="perl -S plackup -s Starman -E $PLACK_ENV -p $PORT -o 0.0.0.0 ${CATALYST_HOME}/script/comserv_server.psgi"
  echo "[supervisor-config] Using 'perl -S plackup' with Starman"
fi

# Ensure log directory exists
mkdir -p ${CATALYST_HOME}/root/log
chmod 755 ${CATALYST_HOME}/root/log

# Build environment variables for supervisor
ENV_VARS="PATH=/opt/comserv/local/bin:/opt/comserv/script:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_VARS="$ENV_VARS,PERL_LOCAL_LIB_ROOT=/opt/comserv/local"
ENV_VARS="$ENV_VARS,PERL5LIB=/opt/comserv/local/lib/perl5"
ENV_VARS="$ENV_VARS,CATALYST_ENV=$CATALYST_ENV"
ENV_VARS="$ENV_VARS,CATALYST_DEBUG=$CATALYST_DEBUG"
ENV_VARS="$ENV_VARS,WEB_PORT=$PORT"

# Pass through all COMSERV_DB_* environment variables from container env
if env | grep -q '^COMSERV_DB_'; then
  for var in $(env | grep '^COMSERV_DB_' | cut -d= -f1); do
    ENV_VARS="$ENV_VARS,$var=${!var}"
  done
fi

# Create supervisor program configuration
cat > /etc/supervisor/conf.d/comserv.conf << EOFCONF
[program:comserv-server]
command=$START_CMD
directory=${CATALYST_HOME}
user=comserv
autostart=true
autorestart=true
startsecs=10
stopasgroup=true
stdout_logfile=${CATALYST_HOME}/root/log/catalyst.log
stdout_logfile_maxbytes=0
stderr_logfile=${CATALYST_HOME}/root/log/catalyst_error.log
stderr_logfile_maxbytes=0
environment=$ENV_VARS
EOFCONF

echo "[supervisor-config] Generated supervisor config:"
echo "[supervisor-config] Command: $START_CMD"
echo "[supervisor-config] Log file: ${CATALYST_HOME}/root/log/catalyst.log"
echo "[supervisor-config] Error log: ${CATALYST_HOME}/root/log/catalyst_error.log"
