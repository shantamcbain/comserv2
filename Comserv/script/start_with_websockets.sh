#!/bin/bash
# Start Comserv with Twiggy for WebSocket support (delegates to comserv_server.pl)

cd "$(dirname "$0")/.."

PORT="${1:-3001}"

exec perl script/comserv_server.pl --twiggy -p "$PORT" -r