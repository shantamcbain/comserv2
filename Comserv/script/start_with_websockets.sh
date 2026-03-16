#!/bin/bash
# Start Comserv with Twiggy for WebSocket support

cd "$(dirname "$0")/.."

PORT="${1:-3001}"

echo "Starting Comserv with Twiggy (WebSocket support) on port $PORT..."
echo "Press Ctrl+C to stop"

# Set up local lib paths
export PERL5LIB="$(pwd)/local/lib/perl5:$PERL5LIB"

# Use the local plackup if available, otherwise use system plackup
if [ -x "$(pwd)/local/bin/plackup" ]; then
    PLACKUP="$(pwd)/local/bin/plackup"
else
    PLACKUP="plackup"
fi

$PLACKUP -s Twiggy \
    -p $PORT \
    -E development \
    -I lib \
    -I local/lib/perl5 \
    -a script/comserv_server.psgi \
    -R lib,root
