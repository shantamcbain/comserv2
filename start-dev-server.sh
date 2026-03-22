#!/bin/bash
# Development Server Startup Script
# Runs Catalyst server on port 4006 with debug mode outside Zenflow
# This prevents resource consumption in the main Zenflow workspace

cd "$(dirname "$0")/Comserv"

echo "========================================="
echo "Starting Comserv Development Server"
echo "========================================="
echo "Port: 4006"
echo "Debug: Enabled"
echo "Auto-restart: Enabled (-r flag)"
echo "========================================="
echo ""

# Check if port 4006 is already in use
if lsof -Pi :4006 -sTCP:LISTEN -t >/dev/null ; then
    echo "ERROR: Port 4006 is already in use"
    echo "Kill the existing process with: kill \$(lsof -t -i:4006)"
    exit 1
fi

# Check if GROK_API_KEY is set (optional warning)
if [ -z "$GROK_API_KEY" ]; then
    echo "WARNING: GROK_API_KEY environment variable not set"
    echo "Grok provider will not be available"
    echo "Set with: export GROK_API_KEY='your-key-here'"
    echo ""
fi

# Check if Kubernetes secret exists (alternative to env var)
if [ -f "/run/secrets/grok_api_key" ]; then
    echo "INFO: Found Kubernetes secret for Grok API key at /run/secrets/grok_api_key"
    echo ""
fi

# Start the server with debug mode and auto-restart
echo "Starting server..."
CATALYST_DEBUG=1 script/comserv_server.pl -p 4006 -r

# Note: -r flag enables auto-restart on file changes
# This is useful for development but should NOT be used in production
