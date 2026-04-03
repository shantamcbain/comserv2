#!/bin/bash
# comserv-docker-start.sh
# Wait for NFS server availability, then start Docker Compose services.
# Called by comserv-docker.service on boot.

set -e

NFS_HOST="${NFS_SERVER:-192.168.1.175}"
COMPOSE_DIR="/home/shanta/PycharmProjects/comserv2"
MAX_WAIT=120
WAIT_INTERVAL=5

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Comserv Docker Boot Startup ==="
log "Waiting for NFS server ${NFS_HOST} (up to ${MAX_WAIT}s)..."

elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if ping -c 1 -W 2 "$NFS_HOST" >/dev/null 2>&1; then
        log "NFS server ${NFS_HOST} is reachable after ${elapsed}s"
        break
    fi
    sleep $WAIT_INTERVAL
    elapsed=$((elapsed + WAIT_INTERVAL))
done

if [ $elapsed -ge $MAX_WAIT ]; then
    log "WARNING: NFS server ${NFS_HOST} not reachable after ${MAX_WAIT}s — starting containers anyway (NFS mount may fail)"
fi

log "Starting Docker Compose services in ${COMPOSE_DIR}..."
cd "$COMPOSE_DIR"

docker compose up -d 2>&1 | while IFS= read -r line; do log "$line"; done

log "=== Docker Compose startup complete ==="
log "Running containers:"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true
