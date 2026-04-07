#!/bin/bash
set -e

EMAIL="csc@computersystemconsulting.ca"
COMPOSE_FILE="/opt/comserv/Comserv/docker-compose.server.yml"
IMAGE="shantamcsbain/comserv-web-prod:latest"
CONTAINER="comserv2-web-prod"
DEPLOY_LOG="/var/log/comserv-deploy.log"
HOSTNAME_VAL=$(hostname)

echo "=== Comserv Production Deploy Check at $(date) ==="

# ── Disk space report ────────────────────────────────────────────────────────
DISK_BEFORE=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
echo "Disk before: $DISK_BEFORE"

# ── Routine cleanup (runs every time, not just on deploy) ────────────────────
echo "Running routine Docker cleanup..."
docker container prune -f  --filter "until=1h"  2>&1 | grep -v "^$" || true
docker image prune -f                                   2>&1 | grep -v "^$" || true
docker builder prune -f    --keep-storage 2GB           2>&1 | grep -v "^$" || true

DISK_AFTER_CLEANUP=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
echo "Disk after cleanup: $DISK_AFTER_CLEANUP"

# ── Disk space alert (warn at 85%) ───────────────────────────────────────────
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if [ "$DISK_PCT" -ge 85 ] && command -v mail >/dev/null 2>&1; then
    DISK_DETAIL=$(df -h / | awk 'NR==2 {print $3 " used of " $2 " (" $5 " full)"}')
    DOCKER_USAGE=$(docker system df 2>/dev/null || echo "unavailable")
    echo "WARNING: Disk at ${DISK_PCT}% — sending alert"
    echo -e "Production server disk space alert\n\nServer : $HOSTNAME_VAL\nTime   : $(date)\nDisk   : $DISK_DETAIL\n\nDocker usage:\n$DOCKER_USAGE" \
        | mail -s "⚠️  Disk ${DISK_PCT}% full on $HOSTNAME_VAL" "$EMAIL"
fi

# ── Deploy log rotation (keep last 5000 lines) ───────────────────────────────
if [ -f "$DEPLOY_LOG" ] && [ $(wc -l < "$DEPLOY_LOG") -gt 6000 ]; then
    tail -5000 "$DEPLOY_LOG" > "${DEPLOY_LOG}.tmp" && mv "${DEPLOY_LOG}.tmp" "$DEPLOY_LOG"
    echo "Deploy log rotated (kept last 5000 lines)"
fi

# ── Container log trimming (cap at 100 MB) ───────────────────────────────────
LOG_FILE=$(docker inspect --format='{{.LogPath}}' "$CONTAINER" 2>/dev/null || true)
if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(du -m "$LOG_FILE" | cut -f1)
    if [ "$LOG_SIZE" -gt 100 ]; then
        echo "Trimming container log (${LOG_SIZE}MB -> 10MB)..."
        tail -c 10485760 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi

# ── Check for compose file ───────────────────────────────────────────────────
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: $COMPOSE_FILE not found. Aborting." >&2
    exit 1
fi

cd "$(dirname "$COMPOSE_FILE")"

# ── Version check ────────────────────────────────────────────────────────────
echo "Checking for new image on Docker Hub..."

LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo "none")
REMOTE_DIGEST=$(docker manifest inspect "$IMAGE" 2>/dev/null \
    | grep -o '"digest":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "none")

echo "  Local : ${LOCAL_DIGEST:0:72}..."
echo "  Remote: ${REMOTE_DIGEST:0:72}..."

if [ "$LOCAL_DIGEST" = "$REMOTE_DIGEST" ] && [ "$LOCAL_DIGEST" != "none" ]; then
    DISK_FINAL=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
    echo "No new version. Disk: $DISK_FINAL"
    echo "=== Finished at $(date) ==="
    exit 0
fi

echo "New version detected. Starting deployment..."

echo "1. Pulling latest image..."
docker compose -f "$COMPOSE_FILE" pull

VERSION_INFO=$(docker inspect --format='{{index .Config.Labels "app.version"}}' "$IMAGE" 2>/dev/null || true)
if [ -z "$VERSION_INFO" ]; then
    VERSION_INFO=$(docker run --rm --entrypoint cat "$IMAGE" /opt/comserv/version.json 2>/dev/null || echo '{}')
fi
echo "   Version: $VERSION_INFO"

echo "2. Stopping and removing old container..."
docker stop "$CONTAINER"  2>/dev/null || true
docker rm -f "$CONTAINER" 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

echo "3. Starting new container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "4. Waiting for health check (up to 90s)..."
ATTEMPT=0
HEALTHY=0
while [ $ATTEMPT -lt 45 ]; do
    sleep 2
    ATTEMPT=$((ATTEMPT + 1))
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "healthy" ]; then
        HEALTHY=1
        break
    fi
    [ $((ATTEMPT % 5)) -eq 0 ] && echo "  ...waiting ($((ATTEMPT * 2))s)"
done

echo "5. Post-deploy cleanup (remove now-dangling old image layers)..."
docker image prune -f 2>&1 | grep -v "^$" || true

DISK_FINAL=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
echo "Disk after deploy: $DISK_FINAL"

docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

if [ $HEALTHY -eq 1 ]; then
    echo "=== Deployment Successful at $(date) ==="
    STATUS_MSG="SUCCESS"
    SUBJECT="Comserv Production Updated Successfully"
else
    echo "WARNING: Container did not reach healthy state within 90s"
    STATUS_MSG="DEPLOYED (health check inconclusive)"
    SUBJECT="Comserv Production Deployed - Health Check Timeout"
fi

if command -v mail >/dev/null 2>&1; then
    echo -e "Comserv Production Deployment Report\n\nServer    : $HOSTNAME_VAL\nTime      : $(date)\nImage     : $IMAGE\nContainer : $CONTAINER\nStatus    : $STATUS_MSG\nVersion   : $VERSION_INFO\nNew digest: ${REMOTE_DIGEST:0:72}\nDisk      : $DISK_FINAL" \
        | mail -s "$SUBJECT" "$EMAIL"
    echo "Notification sent to $EMAIL"
fi
