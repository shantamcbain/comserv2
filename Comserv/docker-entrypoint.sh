#!/bin/bash
set -e

# Default values
PORT="${PORT:-3000}"
WORKERS="${WORKERS:-4}"
ENVIRONMENT="${ENVIRONMENT:-development}"

echo "=== Comserv Starting ==="
echo "Environment: $ENVIRONMENT"
echo "Port: $PORT"
echo "Workers: $WORKERS"

if [ "$ENVIRONMENT" = "production" ] || [ "$ENVIRONMENT" = "staging" ]; then
    echo "→ Starting with Starman (production-grade server)"

    # Make sure we have a .psgi file (create one if missing)
    if [ ! -f "comserv.psgi" ]; then
        echo "Creating comserv.psgi..."
        cat > comserv.psgi << 'EOF'
use lib 'lib';
use Comserv;
use Plack::Builder;

builder {
    enable 'Plack::Middleware::ReverseProxy';
    Comserv->psgi_app(@_);
};
EOF
    fi

    exec plackup -s Starman \
        --workers "$WORKERS" \
        --port "$PORT" \
        --access-log /dev/stdout \
        --error-log /dev/stderr \
        comserv.psgi

else
    echo "→ Starting development server (comserv_server.pl)"
    exec perl -Ilib script/comserv_server.pl --port "$PORT" "$@"
fi