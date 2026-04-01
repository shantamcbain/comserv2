#!/bin/bash
set -e

EMAIL="csc@computersystemconsulting.ca"
COMPOSE_FILE="/opt/comserv/Comserv/docker-compose.server.yml"
IMAGE="shantamcsbain/comserv-web-prod:latest"
CONTAINER="comserv2-web-prod"
LOG="/var/log/comserv-deploy.log"
HOSTNAME_VAL=$(hostname)

echo "=== Comserv Production Deploy Check at $(date) ==="

if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: $COMPOSE_FILE not found. Aborting." >&2
    exit 1
fi

cd "$(dirname "$COMPOSE_FILE")"

echo "Checking for new image on Docker Hub..."

LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo "none")
REMOTE_DIGEST=$(docker manifest inspect "$IMAGE" 2>/dev/null \
    | grep -o '"digest":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "none")

echo "  Local : ${LOCAL_DIGEST:0:72}..."
echo "  Remote: ${REMOTE_DIGEST:0:72}..."

if [ "$LOCAL_DIGEST" = "$REMOTE_DIGEST" ] && [ "$LOCAL_DIGEST" != "none" ]; then
    echo "No new version available. Skipping deployment."
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
docker stop "$CONTAINER" 2>/dev/null || true
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

echo "5. Cleaning up old images..."
docker image prune -f

if [ $HEALTHY -eq 1 ]; then
    echo "=== Deployment Successful at $(date) ==="
    STATUS_MSG="SUCCESS"
    SUBJECT="Comserv Production Updated Successfully"
else
    echo "WARNING: Container did not reach healthy state within 90s"
    STATUS_MSG="DEPLOYED (health check inconclusive)"
    SUBJECT="Comserv Production Deployed - Health Check Timeout"
fi

docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

if command -v mail >/dev/null 2>&1; then
    echo -e "Comserv Production Deployment Report\n\nServer    : $HOSTNAME_VAL\nTime      : $(date)\nImage     : $IMAGE\nContainer : $CONTAINER\nStatus    : $STATUS_MSG\nVersion   : $VERSION_INFO\nNew digest: ${REMOTE_DIGEST:0:72}" \
        | mail -s "$SUBJECT" "$EMAIL"
    echo "Notification sent to $EMAIL"
fi
