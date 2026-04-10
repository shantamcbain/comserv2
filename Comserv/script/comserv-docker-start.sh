#!/bin/bash
# comserv-docker-start.sh
# Optionally mounts NFS workshop share on the host, then starts Docker Compose.
# Containers use a local bind mount so they start even if NFS is unavailable.

set -e

NFS_HOST="${NFS_SERVER:-192.168.1.175}"
NFS_EXPORT="${NFS_WORKSHOP_PATH:-/mnt/data/comserv}"
WORKSHOP_LOCAL_DIR="${WORKSHOP_LOCAL_DIR:-/home/shanta/comserv-workshop}"
COMPOSE_DIR="/home/shanta/PycharmProjects/comserv2"
MAX_WAIT=60

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== Comserv Docker Boot Startup ==="

# Ensure the local workshop directory exists
mkdir -p "$WORKSHOP_LOCAL_DIR"

# Check if NFS server is reachable on port 2049
log "Checking NFS server ${NFS_HOST}:2049 (up to ${MAX_WAIT}s)..."
elapsed=0
NFS_OK=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if nc -z -w 2 "$NFS_HOST" 2049 >/dev/null 2>&1; then
        NFS_OK=1
        log "NFS server reachable after ${elapsed}s"
        break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
done

# Mount NFS on the host directory if available and not already mounted
if [ $NFS_OK -eq 1 ]; then
    if mountpoint -q "$WORKSHOP_LOCAL_DIR"; then
        log "NFS already mounted at ${WORKSHOP_LOCAL_DIR}"
    else
        log "Mounting NFS ${NFS_HOST}:${NFS_EXPORT} -> ${WORKSHOP_LOCAL_DIR}"
        if mount -t nfs -o "rw,noatime,nfsvers=3,soft,timeo=14" \
            "${NFS_HOST}:${NFS_EXPORT}" "$WORKSHOP_LOCAL_DIR" 2>&1; then
            log "NFS mounted successfully"
        else
            log "WARNING: NFS mount failed — containers will start without workshop files"
        fi
    fi
else
    log "WARNING: NFS server not reachable after ${MAX_WAIT}s — starting containers without workshop files"
fi

log "Starting Docker Compose services in ${COMPOSE_DIR}..."
cd "$COMPOSE_DIR"

docker compose up -d 2>&1 | while IFS= read -r line; do log "$line"; done

log "=== Docker Compose startup complete ==="
log "Running containers:"
docker ps --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true
