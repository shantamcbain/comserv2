#!/bin/bash

PORT=${WEB_PORT:-3000}
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
CATALYST_ENV=${CATALYST_ENV:-production}
CATALYST_DEBUG=${CATALYST_DEBUG:-0}

echo "[supervisor-config] Configuring Starman with WEB_PORT=$PORT, CATALYST_ENV=$CATALYST_ENV, DEBUG=$CATALYST_DEBUG"
echo "[supervisor-config] Supervisor will capture all Starman output to log files and supervisord logs"

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

# Use startup wrapper to pre-test module loading and capture errors
# The wrapper will run pre-flight checks and log any issues clearly
START_CMD="${CATALYST_HOME}/startup-wrapper.sh"
echo "[supervisor-config] Using startup wrapper: $START_CMD"

# Ensure log directory exists
mkdir -p ${CATALYST_HOME}/root/log
chmod 755 ${CATALYST_HOME}/root/log

# Build environment variables for supervisor
ENV_VARS="PATH=/opt/comserv/local/bin:/opt/comserv/script:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV_VARS="$ENV_VARS,PERL_LOCAL_LIB_ROOT=/opt/comserv/local"
ENV_VARS="$ENV_VARS,PERL5LIB=/opt/comserv/lib:/opt/comserv/local/lib/perl5"
ENV_VARS="$ENV_VARS,CATALYST_ENV=$CATALYST_ENV"
ENV_VARS="$ENV_VARS,CATALYST_DEBUG=$CATALYST_DEBUG"
ENV_VARS="$ENV_VARS,WEB_PORT=$PORT"
ENV_VARS="$ENV_VARS,COMSERV_LOG_DIR=/opt/comserv"

# Pass through all COMSERV_DB_, WORKSHOP_, SYSTEM_IDENTIFIER and HEALTH_ environment variables from container env
if env | grep -qE '^(COMSERV_DB_|WORKSHOP_|SYSTEM_IDENTIFIER|HEALTH_)'; then
  for var in $(env | grep -E '^(COMSERV_DB_|WORKSHOP_|SYSTEM_IDENTIFIER|HEALTH_)' | cut -d= -f1); do
    ENV_VARS="$ENV_VARS,$var=${!var}"
  done
fi

# Create supervisor program configuration.
# stdout/stderr go to BOTH a log file (mounted volume) AND /proc/1/fd/1 (container stdout)
# so that "docker logs" shows app output on the production server.
cat > /etc/supervisor/conf.d/comserv.conf << EOFCONF
[program:comserv-server]
command=$START_CMD
directory=${CATALYST_HOME}
user=comserv
autostart=true
autorestart=unexpected
startsecs=10
stopasgroup=true
stdout_logfile=/proc/1/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/proc/1/fd/2
stderr_logfile_maxbytes=0
environment=$ENV_VARS
priority=999

[program:comserv-health-monitor]
command=${CATALYST_HOME}/script/ContainerHealthMonitor.pl
directory=${CATALYST_HOME}
user=comserv
autostart=true
autorestart=true
startsecs=5
stdout_logfile=/proc/1/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/proc/1/fd/2
stderr_logfile_maxbytes=0
environment=$ENV_VARS
priority=1000
EOFCONF

echo "[supervisor-config] Generated supervisor config:"
echo "[supervisor-config] Command: $START_CMD"
echo "[supervisor-config] Logs: container stdout/stderr (visible via 'docker logs')"

# Write config to supervisord log so we can see it in docker logs
echo "[supervisor-config] ===== Supervisor config generated =====" >> /var/log/supervisor/supervisord.log 2>&1 || true
cat /etc/supervisor/conf.d/comserv.conf >> /var/log/supervisor/supervisord.log 2>&1 || true
echo "[supervisor-config] ===== End config =====" >> /var/log/supervisor/supervisord.log 2>&1 || true
