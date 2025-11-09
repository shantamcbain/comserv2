#!/bin/bash
PORT=${WEB_PORT:-3000}
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
DEBUG_FLAG=""
if [ "$CATALYST_ENV" = "development" ]; then
    DEBUG_FLAG="-r"
fi
cat > /etc/supervisor/conf.d/comserv.conf << EOFCONF
[program:comserv-server]
command=${CATALYST_HOME}/script/comserv_server.pl -p $PORT $DEBUG_FLAG
directory=${CATALYST_HOME}
user=comserv
autostart=true
autorestart=true
stdout_logfile=${CATALYST_HOME}/root/log/catalyst.log
stderr_logfile=${CATALYST_HOME}/root/log/catalyst_error.log
EOFCONF
