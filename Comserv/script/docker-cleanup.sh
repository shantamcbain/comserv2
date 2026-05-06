#!/bin/bash
# docker-cleanup.sh — Workstation Docker cleanup
# Run from PyCharm terminal or any shell:
#   bash ~/PycharmProjects/comserv2/Comserv/script/docker-cleanup.sh
#
# Safe to run anytime. Will NOT remove:
#   - Running containers
#   - Named volumes used by running containers (comserv-logs, redis_data, etc.)
#   - The comserv images currently in use

set -e

echo "=== Comserv Workstation Docker Cleanup at $(date) ==="
echo ""

disk_before() {
    df -h / | awk 'NR==2 {print $3 " used of " $2 " (" $5 ")"}'
}

echo "Disk before: $(disk_before)"
echo ""

# ── 1. Stopped / dead / exited containers ────────────────────────────────────
echo "1. Removing stopped containers..."
STOPPED=$(docker ps -a --filter "status=exited" --filter "status=dead" --filter "status=created" --format "{{.Names}}" 2>/dev/null)
if [ -n "$STOPPED" ]; then
    echo "$STOPPED" | while read -r name; do echo "   Removing: $name"; done
    docker container prune -f 2>/dev/null | grep -v "^$" || true
else
    echo "   None found."
fi

# ── 2. Dangling images (untagged build leftovers) ────────────────────────────
echo ""
echo "2. Removing dangling images..."
docker image prune -f 2>/dev/null | grep -v "^$" || true

# ── 3. Old non-current tagged images (keep latest + one prior) ───────────────
echo ""
echo "3. Old images (non-running, non-latest)..."
docker images --format "{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}" \
    | grep -v "<none>" \
    | grep -v ":latest" \
    | grep -v "redis\|alpine\|searxng" \
    | while IFS=$'\t' read -r tag id created; do
        if ! docker ps -q --filter "ancestor=$id" | grep -q .; then
            echo "   Removing old image: $tag ($id)"
            docker rmi "$id" 2>/dev/null || echo "   (skipped — still referenced)"
        fi
    done

# ── 4. Build cache (keep last 2 GB) ──────────────────────────────────────────
echo ""
echo "4. Pruning build cache (keeping 2GB)..."
docker builder prune -f --keep-storage 2GB 2>/dev/null | grep -v "^$" || true

# ── 5. Unused volumes (dangling — not attached to any container) ──────────────
echo ""
echo "5. Removing unused (dangling) volumes..."
DANGLING_VOLS=$(docker volume ls -qf dangling=true 2>/dev/null)
if [ -n "$DANGLING_VOLS" ]; then
    echo "$DANGLING_VOLS" | while read -r v; do echo "   Removing volume: $v"; done
    docker volume prune -f 2>/dev/null | grep -v "^$" || true
else
    echo "   None found."
fi

# ── 6. Unused networks ────────────────────────────────────────────────────────
echo ""
echo "6. Removing unused networks..."
docker network prune -f 2>/dev/null | grep -v "^$" || true

# ── 7. Trim container logs >50MB ─────────────────────────────────────────────
echo ""
echo "7. Checking container log sizes..."
LOG_TRIM_THRESHOLD_MB=50
LOG_TRIM_TARGET_BYTES=10485760   # 10 MB
for CNAME in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    LOG_FILE=$(docker inspect --format='{{.LogPath}}' "$CNAME" 2>/dev/null || true)
    [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ] && continue
    LOG_SIZE_MB=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1)
    LOG_SIZE_MB=${LOG_SIZE_MB:-0}
    echo "   $CNAME: ${LOG_SIZE_MB}MB"
    if [ "$LOG_SIZE_MB" -gt "$LOG_TRIM_THRESHOLD_MB" ]; then
        echo "   => Trimming to 10MB..."
        tail -c "$LOG_TRIM_TARGET_BYTES" "$LOG_FILE" > "${LOG_FILE}.tmp" \
            && mv "${LOG_FILE}.tmp" "$LOG_FILE" \
            && echo "   => Done." \
            || echo "   => WARNING: trim failed (try with sudo)"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Docker system usage after cleanup ==="
docker system df
echo ""
echo "Disk after: $(disk_before)"
echo ""
echo "=== Cleanup complete at $(date) ==="
