#!/bin/bash
PORT=${WEB_PORT:-3000}
CATALYST_HOME=${CATALYST_HOME:-/opt/comserv}
cat > /etc/supervisor/conf.d/comserv.conf << EOFCONF
[program:comserv-starman]
command=${CATALYST_HOME}/local/bin/starman --workers=4 --port=$PORT --app ${CATALYST_HOME}/script/comserv_server.pl
directory=${CATALYST_HOME}
user=comserv
autostart=true
autorestart=true
stdout_logfile=${CATALYST_HOME}/root/log/starman.log
stderr_logfile=${CATALYST_HOME}/root/log/starman_error.log
EOFCONF
