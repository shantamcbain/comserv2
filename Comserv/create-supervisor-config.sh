#!/bin/bash
PORT=${WEB_PORT:-3000}
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
# Use Starman consistently for robustness and identical behavior in dev/prod
# Map Catalyst env to Plack/Starman
PLACK_ENV="deployment"
if [ "$CATALYST_ENV" = "development" ]; then
    PLACK_ENV="development"
fi

# Prefer starman; fallback to plackup -s Starman if starman binary not found
if command -v starman >/dev/null 2>&1; then
  START_CMD="starman --env $PLACK_ENV --listen :$PORT --host 0.0.0.0 --workers 2 ${CATALYST_HOME}/script/comserv_server.psgi"
else
  START_CMD="plackup -s Starman -E $PLACK_ENV -p $PORT -o 0.0.0.0 ${CATALYST_HOME}/script/comserv_server.psgi"
fi

cat > /etc/supervisor/conf.d/comserv.conf << EOFCONF
[program:comserv-server]
command=$START_CMD
directory=${CATALYST_HOME}
user=comserv
autostart=true
autorestart=true
stdout_logfile=${CATALYST_HOME}/root/log/catalyst.log
stderr_logfile=${CATALYST_HOME}/root/log/catalyst_error.log
EOFCONF
