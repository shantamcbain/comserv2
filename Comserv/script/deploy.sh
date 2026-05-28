#!/bin/bash
set -e

# Ensure standard system bin paths are included in PATH (critical for non-interactive SSH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

EMAIL="csc@computersystemconsulting.ca"
COMPOSE_FILE="/opt/comserv/Comserv/docker-compose.server.yml"
IMAGE="shantamcsbain/comserv-web-prod:latest"
CONTAINER="comserv2-web-prod"
DEPLOY_LOG="/var/log/comserv-deploy.log"
HOSTNAME_VAL=$(hostname)

echo "=== Comserv Production Deploy Check at $(date) ==="

# ── Detect NFS and configure paths ───────────────────────────────────────────
# Production server: /home/ubuntu/nfs (mounted from 192.168.1.175:/mnt/data)
# Workstation:       /home/shanta/nfs (mounted from 192.168.1.175:/mnt/data)
NFS_MOUNT_CANDIDATES="/home/ubuntu/nfs /home/shanta/nfs /mnt/nfs /mnt/data"
NFS_MOUNT_DIR=""
for candidate in $NFS_MOUNT_CANDIDATES; do
    if mount | grep -q " on ${candidate} type nfs"; then
        NFS_MOUNT_DIR="$candidate"
        break
    fi
done

# Default paths (local fallback if NFS not mounted)
COMSERV_LOGS_DIR="/var/log/comserv"
NFS_DATA_DIR="/var/lib/comserv/data"
NFS_DEPLOY_LOG=""

if [ -n "$NFS_MOUNT_DIR" ]; then
    echo "NFS detected at $NFS_MOUNT_DIR"
    COMSERV_LOGS_DIR="$NFS_MOUNT_DIR/comserv-logs"
    NFS_DATA_DIR="$NFS_MOUNT_DIR"
    mkdir -p "$COMSERV_LOGS_DIR" 2>/dev/null || true
    echo "   Container logs: $COMSERV_LOGS_DIR"
    echo "   NFS data dir:   $NFS_DATA_DIR"
    
    # Configure NFS Deployment Log archive path
    NFS_LOG_DIR="$NFS_MOUNT_DIR/logs"
    mkdir -p "$NFS_LOG_DIR" 2>/dev/null || true
    if [ -d "$NFS_LOG_DIR" ] && [ -w "$NFS_LOG_DIR" ]; then
        NFS_DEPLOY_LOG="${NFS_LOG_DIR}/comserv-deploy.log"
    fi
else
    echo "NFS not mounted — using local fallbacks"
    echo "   Container logs: $COMSERV_LOGS_DIR"
    echo "   Data dir:       $NFS_DATA_DIR"
    mkdir -p "$COMSERV_LOGS_DIR" "$NFS_DATA_DIR" 2>/dev/null || true
fi

# ── Export environment variables for docker-compose ──────────────────────────
# CRITICAL: Must export BEFORE any docker-compose commands (including pull)
export COMSERV_LOGS_DIR
export NFS_DATA_DIR

# ── Disk space report ────────────────────────────────────────────────────────
DISK_BEFORE=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
echo "Disk before: $DISK_BEFORE"

# ── Routine cleanup (runs every cron tick, not just on deploy) ───────────────
echo "Running routine Docker cleanup..."
docker container prune -f --filter "until=1h" 2>&1 | grep -v "^$" || true
# Prune ONLY dangling (untagged) images to protect tagged rollback/backup images
docker image prune -f                          2>&1 | grep -v "^$" || true
docker volume prune -f                         2>&1 | grep -v "^$" || true
docker network prune -f                        2>&1 | grep -v "^$" || true
# Completely purge build cache since server only pulls pre-built production images
docker builder prune -a -f                     2>&1 | grep -v "^$" || true

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

# ── Container log trimming (runs every cron tick for ALL comserv containers) ──
# Caps each container log at LOG_TRIM_THRESHOLD_MB; trims to LOG_TRIM_TARGET_MB.
LOG_TRIM_THRESHOLD_MB=50
LOG_TRIM_TARGET_BYTES=10485760   # 10 MB kept after trim

echo "Checking container log sizes..."
for CNAME in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    LOG_FILE=$(docker inspect --format='{{.LogPath}}' "$CNAME" 2>/dev/null || true)
    [ -z "$LOG_FILE" ] && continue
    
    # Check if we can write to the log file (docker logs are owned by root)
    if [ ! -w "$LOG_FILE" ]; then
        if command -v sudo >/dev/null 2>&1; then
            LOG_SIZE_MB=$(sudo du -m "$LOG_FILE" 2>/dev/null | cut -f1)
            LOG_SIZE_MB=${LOG_SIZE_MB:-0}
            echo "  $CNAME: ${LOG_SIZE_MB}MB (requires sudo)"
            if [ "$LOG_SIZE_MB" -gt "$LOG_TRIM_THRESHOLD_MB" ]; then
                echo "  => Trimming $CNAME log (${LOG_SIZE_MB}MB -> 10MB) via sudo..."
                sudo tail -c "$LOG_TRIM_TARGET_BYTES" "$LOG_FILE" > "/tmp/${CNAME}_log.tmp" \
                    && sudo mv "/tmp/${CNAME}_log.tmp" "$LOG_FILE" \
                    && sudo chmod 640 "$LOG_FILE" \
                    && echo "  => Done." \
                    || echo "  => WARNING: sudo trim failed for $CNAME"
            fi
        else
            echo "  $CNAME: Cannot access $LOG_FILE (permission denied, sudo not available)"
        fi
    else
        LOG_SIZE_MB=$(du -m "$LOG_FILE" 2>/dev/null | cut -f1)
        LOG_SIZE_MB=${LOG_SIZE_MB:-0}
        echo "  $CNAME: ${LOG_SIZE_MB}MB"
        if [ "$LOG_SIZE_MB" -gt "$LOG_TRIM_THRESHOLD_MB" ]; then
            echo "  => Trimming $CNAME log (${LOG_SIZE_MB}MB -> 10MB)..."
            tail -c "$LOG_TRIM_TARGET_BYTES" "$LOG_FILE" > "${LOG_FILE}.tmp" \
                && mv "${LOG_FILE}.tmp" "$LOG_FILE" \
                && echo "  => Done." \
                || echo "  => WARNING: trim failed for $CNAME"
        fi
    fi
done

# ── Application log trimming (on host) ───────────────────────────────────────
echo "Checking application log sizes in $COMSERV_LOGS_DIR..."
if [ -d "$COMSERV_LOGS_DIR" ]; then
    find "$COMSERV_LOGS_DIR" -name "*.log" -type f 2>/dev/null | while read -r ALOG; do
        ASIZE_MB=$(du -m "$ALOG" 2>/dev/null | cut -f1)
        ASIZE_MB=${ASIZE_MB:-0}
        echo "  $ALOG: ${ASIZE_MB}MB"
        if [ "$ASIZE_MB" -gt "$LOG_TRIM_THRESHOLD_MB" ]; then
            echo "  => Trimming application log $ALOG (${ASIZE_MB}MB -> 10MB)..."
            tail -c "$LOG_TRIM_TARGET_BYTES" "$ALOG" > "${ALOG}.tmp" \
                && mv "${ALOG}.tmp" "$ALOG" \
                && chmod 664 "$ALOG" 2>/dev/null || true
        fi
    done
    # Also delete any rotated logs older than 7 days on the host
    echo "Pruning rotated application logs older than 7 days..."
    find "$COMSERV_LOGS_DIR" \( -name "*.log.*" -o -name "*.gz" \) -mtime +7 -type f -delete 2>/dev/null || true
fi

# ── Check for compose file ─���───────────────────────────────────────────���─────
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

# ── Rotate rollback/backup images ────────────────────────────────────────────
echo "Rotating rollback/backup images..."
# Remove oldest backup (backup-2) if it exists
docker rmi shantamcsbain/comserv-web-prod:backup-2 2>/dev/null || true
# Move backup-1 to backup-2
if docker image inspect shantamcsbain/comserv-web-prod:backup-1 >/dev/null 2>&1; then
    docker tag shantamcsbain/comserv-web-prod:backup-1 shantamcsbain/comserv-web-prod:backup-2
    docker rmi shantamcsbain/comserv-web-prod:backup-1 2>/dev/null || true
fi
# Move current latest to backup-1
if docker image inspect shantamcsbain/comserv-web-prod:latest >/dev/null 2>&1; then
    docker tag shantamcsbain/comserv-web-prod:latest shantamcsbain/comserv-web-prod:backup-1
fi

echo "1. Pulling latest image..."
docker compose -f "$COMPOSE_FILE" pull

VERSION_INFO=$(docker inspect --format='{{index .Config.Labels "app.version"}}' "$IMAGE" 2>/dev/null || true)
if [ -z "$VERSION_INFO" ]; then
    VERSION_INFO=$(docker run --rm --entrypoint cat "$IMAGE" /opt/comserv/version.json 2>/dev/null || echo '{}')
fi
echo "   Version: $VERSION_INFO"

echo "2. Stopping and removing old container..."
docker stop "$CONTAINER" comserv-web-prod 2>/dev/null || true
docker rm -f "$CONTAINER" comserv-web-prod 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true

echo "2b. Checking for host processes occupying port 5000/3000 outside Docker..."
# Stop host port 5000 processes to prevent "port already in use" binding errors in Docker
HOST_PORT_OCCUPIED=0

# Try to detect with sudo first (non-interactive), then fallback to current user
SUDO_CMD=""
if sudo -n true 2>/dev/null; then
    SUDO_CMD="sudo"
fi

# 1. Terminate any manual Starman or Plackup processes aggressively by process name/command line
echo "   Checking for running starman/plackup/comserv host processes..."
$SUDO_CMD pkill -15 -f "starman" 2>/dev/null || pkill -15 -f "starman" 2>/dev/null || true
$SUDO_CMD pkill -15 -f "plackup" 2>/dev/null || pkill -15 -f "plackup" 2>/dev/null || true
$SUDO_CMD pkill -15 -f "comserv.psgi" 2>/dev/null || pkill -15 -f "comserv.psgi" 2>/dev/null || true
$SUDO_CMD pkill -15 -f "comserv_server.psgi" 2>/dev/null || pkill -15 -f "comserv_server.psgi" 2>/dev/null || true
sleep 1

# 2. Check and terminate anything listening specifically on port 5000
if command -v fuser &>/dev/null; then
    HOST_PIDS=$($SUDO_CMD fuser 5000/tcp 2>/dev/null || fuser 5000/tcp 2>/dev/null || true)
    # Normalize newlines/whitespace to spaces
    HOST_PIDS=$(echo "$HOST_PIDS" | tr '\n' ' ' | xargs || true)
    if [ -n "$HOST_PIDS" ]; then
        echo "   ⚠ Found host process(es) ($HOST_PIDS) occupying port 5000 on the host. Terminating..."
        $SUDO_CMD fuser -k -15 5000/tcp 2>/dev/null || fuser -k -15 5000/tcp 2>/dev/null || true
        sleep 2
        $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
        HOST_PORT_OCCUPIED=1
    fi
elif command -v lsof &>/dev/null; then
    HOST_PIDS=$($SUDO_CMD lsof -t -i:5000 2>/dev/null || lsof -t -i:5000 2>/dev/null || true)
    HOST_PIDS=$(echo "$HOST_PIDS" | tr '\n' ' ' | xargs || true)
    if [ -n "$HOST_PIDS" ]; then
        echo "   ⚠ Found host process(es) ($HOST_PIDS) occupying port 5000 on the host. Terminating..."
        $SUDO_CMD kill -15 $HOST_PIDS 2>/dev/null || kill -15 $HOST_PIDS 2>/dev/null || true
        sleep 2
        $SUDO_CMD kill -9 $HOST_PIDS 2>/dev/null || kill -9 $HOST_PIDS 2>/dev/null || true
        HOST_PORT_OCCUPIED=1
    fi
else
    # Fallback using ss
    HOST_PIDS=$($SUDO_CMD ss -tulpn 2>/dev/null | grep -E ':(5000) ' | grep -o -E 'pid=[0-9]+' | cut -d= -f2 | tr '\n' ' ' | xargs || true)
    if [ -z "$HOST_PIDS" ]; then
        HOST_PIDS=$(ss -tulpn 2>/dev/null | grep -E ':(5000) ' | grep -o -E 'pid=[0-9]+' | cut -d= -f2 | tr '\n' ' ' | xargs || true)
    fi
    if [ -n "$HOST_PIDS" ]; then
        echo "   ⚠ Found host process ($HOST_PIDS) occupying port 5000. Terminating..."
        $SUDO_CMD kill -15 $HOST_PIDS 2>/dev/null || kill -15 $HOST_PIDS 2>/dev/null || true
        sleep 2
        $SUDO_CMD kill -9 $HOST_PIDS 2>/dev/null || kill -9 $HOST_PIDS 2>/dev/null || true
        HOST_PORT_OCCUPIED=1
    fi
fi

# Double check port 5000 after kill signals
PORT_CHECK=$($SUDO_CMD ss -tulpn 2>/dev/null | grep -E ':(5000) ' || true)
if [ -n "$PORT_CHECK" ]; then
    # Force kill starman processes with -9
    echo "   ⚠ Port 5000 still bound. Issuing force-kill to starman processes..."
    $SUDO_CMD pkill -9 -f "starman" 2>/dev/null || pkill -9 -f "starman" 2>/dev/null || true
    $SUDO_CMD pkill -9 -f "plackup" 2>/dev/null || pkill -9 -f "plackup" 2>/dev/null || true
    $SUDO_CMD pkill -9 -f "comserv.psgi" 2>/dev/null || pkill -9 -f "comserv.psgi" 2>/dev/null || true
    $SUDO_CMD pkill -9 -f "comserv_server.psgi" 2>/dev/null || pkill -9 -f "comserv_server.psgi" 2>/dev/null || true
    sleep 1
    HOST_PORT_OCCUPIED=1
fi

if [ $HOST_PORT_OCCUPIED -eq 1 ]; then
    echo "   ✓ Host port 5000 freed successfully"
else
    echo "   ✓ Port 5000 is free on the host"
fi

echo "3. Starting new container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "3b. Ensuring SearXNG container is running..."
SEARXNG_CONFIG_DIR="/opt/comserv/searxng-config"
if ! docker ps --format '{{.Names}}' | grep -q '^searxng$'; then
    echo "  SearXNG not running — starting..."
    mkdir -p "$SEARXNG_CONFIG_DIR"
    if [ ! -f "$SEARXNG_CONFIG_DIR/settings.yml" ]; then
        SECRET=$(openssl rand -hex 32)
        cat > "$SEARXNG_CONFIG_DIR/settings.yml" << SEARXNG_EOF
use_default_settings: true

server:
  secret_key: "$SECRET"
  bind_address: "0.0.0.0:8080"
  public_instance: false

search:
  formats:
    - html
    - json

general:
  instance_name: "Comserv Search"
  donation_url: false
SEARXNG_EOF
        echo "  Created SearXNG config at $SEARXNG_CONFIG_DIR/settings.yml"
    fi
    docker run -d \
        --name searxng \
        --log-opt max-size=10m \
        --log-opt max-file=3 \
        -p 127.0.0.1:8080:8080 \
        --restart unless-stopped \
        -v "$SEARXNG_CONFIG_DIR:/etc/searxng:ro" \
        searxng/searxng
    echo "  SearXNG started on 127.0.0.1:8080"
else
    echo "  SearXNG already running — OK"
fi

echo "4. Waiting for health check (up to 90s) & streaming startup logs..."
ATTEMPT=0
HEALTHY=0
PREV_LINE_COUNT=0
while [ $ATTEMPT -lt 45 ]; do
    sleep 2
    ATTEMPT=$((ATTEMPT + 1))
    
    # Live stream any new container logs
    CURRENT_LOGS=$(docker logs "$CONTAINER" 2>&1 || true)
    CURRENT_LINE_COUNT=$(echo "$CURRENT_LOGS" | wc -l)
    if [ "$CURRENT_LINE_COUNT" -gt "$PREV_LINE_COUNT" ]; then
        echo "$CURRENT_LOGS" | tail -n +$((PREV_LINE_COUNT + 1))
        PREV_LINE_COUNT=$CURRENT_LINE_COUNT
    fi
    
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "healthy" ]; then
        HEALTHY=1
        break
    fi
done

echo "5. Post-deploy cleanup (remove dangling old image layers)..."
docker image prune -f 2>&1 | grep -v "^$" || true

DISK_FINAL=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
echo "Disk after deploy: $DISK_FINAL"

docker ps --filter "name=$CONTAINER" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

DIAGNOSTICS_REPORT=""
if [ $HEALTHY -eq 1 ]; then
    echo "=== Deployment Successful at $(date) ==="
    STATUS_MSG="SUCCESS"
    SUBJECT="✅ Comserv Production Updated Successfully"
else
    echo "❌ ERROR: Container did not reach healthy state within 90s"
    
    # 1. Automatic rollback to backup-1 (rollback container image)
    echo "   Attempting automated rollback to backup-1..."
    FALLBACK_HEALTHY=0
    if docker image inspect shantamcsbain/comserv-web-prod:backup-1 >/dev/null 2>&1; then
        echo "   [Fallback] Found backup-1 image. Stopping and removing failed container..."
        docker stop "$CONTAINER" 2>/dev/null || true
        docker rm -f "$CONTAINER" 2>/dev/null || true
        
        echo "   [Fallback] Re-tagging backup-1 as latest..."
        docker tag shantamcsbain/comserv-web-prod:backup-1 shantamcsbain/comserv-web-prod:latest
        
        echo "   [Fallback] Launching container with rolled-back image..."
        COMSERV_LOGS_DIR="$COMSERV_LOGS_DIR" WORKSHOP_LOCAL_DIR="$NFS_LOCAL_DIR" docker compose -f "$COMPOSE_FILE" up -d --force-recreate
        
        echo "   [Fallback] Checking health of the backup container (up to 60s)..."
        FALLBACK_ATTEMPT=0
        while [ $FALLBACK_ATTEMPT -lt 30 ]; do
            sleep 2
            FALLBACK_ATTEMPT=$((FALLBACK_ATTEMPT + 1))
            STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
            if [ "$STATUS" = "healthy" ]; then
                FALLBACK_HEALTHY=1
                break
            fi
        done
    fi
    
    # 2. Emergency fallback to Host-level manual server (latest git pull code)
    if [ $FALLBACK_HEALTHY -eq 1 ]; then
        echo "   ✅ [Fallback] Successfully rolled back to backup-1! Container is healthy."
        STATUS_MSG="ROLLBACK_SUCCESS (backup-1 image)"
        SUBJECT="⚠ Comserv Production Rolled Back to Backup-1 Image"
    else
        echo "   ❌ [Fallback] Rollback image failed or was not available."
        echo "   [Emergency] Initiating Emergency host-level manual fallback..."
        
        # Stop any failed docker container first to free port 5000
        docker stop "$CONTAINER" 2>/dev/null || true
        docker rm -f "$CONTAINER" 2>/dev/null || true
        
        # Try to locate host git repository to run local git code
        HOST_APP_DIR=""
        if [ -d "/opt/comserv/Comserv" ]; then
            HOST_APP_DIR="/opt/comserv/Comserv"
        elif [ -d "/home/ubuntu/comserv" ]; then
            HOST_APP_DIR="/home/ubuntu/comserv"
        elif [ -d "/home/shanta/PycharmProjects/comserv2" ]; then
            HOST_APP_DIR="/home/shanta/PycharmProjects/comserv2"
        fi
        
        HOST_STARMAN_STARTED=0
        if [ -n "$HOST_APP_DIR" ] && [ -f "$HOST_APP_DIR/script/comserv_server.psgi" ]; then
            echo "   [Emergency] Found host git repository at $HOST_APP_DIR"
            cd "$HOST_APP_DIR"
            
            # Pull latest changes from git main branch to keep code fully up-to-date
            echo "   [Emergency] Pulling latest changes from main branch..."
            if command -v git &>/dev/null; then
                git pull origin main || git pull || echo "   ⚠ Warning: git pull failed, starting with existing local files"
            fi
            
            export CATALYST_HOME="$HOST_APP_DIR"
            export CATALYST_ENV=production
            export COMSERV_LOG_DIR="$HOST_APP_DIR"
            
            # Start Host starman daemon using the last git pull code
            if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$HOST_APP_DIR/script/comserv_server.psgi" >/tmp/host_starman_start.log 2>&1; then
                echo "   ✅ [Emergency] Successfully started manual starman server on host port 5000 (running last git pull)!"
                HOST_STARMAN_STARTED=1
                STATUS_MSG="EMERGENCY_HOST_STARMAN_ONLINE (local git code)"
                SUBJECT="⚠ Emergency: Host-level manual Starman started (Docker down)"
            else
                echo "   ❌ [Emergency] Failed to start manual starman on host. Log:"
                cat /tmp/host_starman_start.log || true
            fi
        fi
        
        if [ $HOST_STARMAN_STARTED -ne 1 ]; then
            STATUS_MSG="FAILURE (unhealthy container & rollback failed)"
            SUBJECT="❌ Comserv Production Deployment FAILURE"
        fi
    fi
    
    # Extract detailed diagnostics to make debugging easy for CSC admin
    DIAGNOSTICS_REPORT="\n\n===========================================================\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}❌ COMSERV CONTAINER FAILURE DIAGNOSTICS REPORT\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}===========================================================\n"
    
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}\n[1] Container State:\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}$(docker inspect --format='Status: {{.State.Status}} | Running: {{.State.Running}} | Error: {{.State.Error}} | ExitCode: {{.State.ExitCode}} | OOMKilled: {{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null || echo 'Container not running')\n"
    
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}\n[2] Detailed Health Log:\n"
    HEALTH_LOG=$(docker inspect --format='{{range .State.Health.Log}}{{.Start}} [Exit: {{.ExitCode}}]:\n{{.Output}}\n{{end}}' "$CONTAINER" 2>/dev/null)
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}${HEALTH_LOG:-'No health check logs found.'}\n"
    
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}\n[3] Last 150 Container Console Logs:\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}$(docker logs --tail 150 "$CONTAINER" 2>&1 || echo 'No container logs available')\n"
    
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}\n[4] Fallback Status:\n"
    if [ $FALLBACK_HEALTHY -eq 1 ]; then
        DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}✓ Successfully rolled back to backup-1 image automatically.\n"
    elif [ ${HOST_STARMAN_STARTED:-0} -eq 1 ]; then
        DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}⚠ Automatically rolled back to emergency HOST manual starman server (local git code).\n"
    else
        DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}❌ Rollback to backup-1 image failed and Emergency host starman failed or was unavailable!\n"
    fi
    
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}\n[5] Manual Copy-Pasteable Rollback Steps:\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}-----------------------------------------------------------\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}To manually roll back to the previous stable version (backup-1):\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}  docker stop comserv2-web-prod && docker rm comserv2-web-prod\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}  docker tag shantamcsbain/comserv-web-prod:backup-1 shantamcsbain/comserv-web-prod:latest\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}  COMSERV_LOGS_DIR=\"$COMSERV_LOGS_DIR\" WORKSHOP_LOCAL_DIR=\"$NFS_LOCAL_DIR\" docker compose -f \"$COMPOSE_FILE\" up -d --force-recreate\n"
    DIAGNOSTICS_REPORT="${DIAGNOSTICS_REPORT}-----------------------------------------------------------\n"
    
    echo -e "$DIAGNOSTICS_REPORT"
fi

if command -v mail >/dev/null 2>&1; then
    MAIL_BODY="Comserv Production Deployment Report\n\n"
    MAIL_BODY="${MAIL_BODY}Server    : $HOSTNAME_VAL\n"
    MAIL_BODY="${MAIL_BODY}Time      : $(date)\n"
    MAIL_BODY="${MAIL_BODY}Image     : $IMAGE\n"
    MAIL_BODY="${MAIL_BODY}Container : $CONTAINER\n"
    MAIL_BODY="${MAIL_BODY}Status    : $STATUS_MSG\n"
    MAIL_BODY="${MAIL_BODY}Version   : $VERSION_INFO\n"
    MAIL_BODY="${MAIL_BODY}New digest: ${REMOTE_DIGEST:0:72}\n"
    MAIL_BODY="${MAIL_BODY}Disk      : $DISK_FINAL\n"
    
    if [ -n "$DIAGNOSTICS_REPORT" ]; then
        MAIL_BODY="${MAIL_BODY}${DIAGNOSTICS_REPORT}"
    fi
    
    echo -e "$MAIL_BODY" | mail -s "$SUBJECT" "$EMAIL"
    echo "Notification sent to $EMAIL"
fi

# ── Archive the deployment log to the NFS drive (if available) ───────────────
if [ -n "$NFS_DEPLOY_LOG" ] && [ -f "$DEPLOY_LOG" ]; then
    echo "=== Deployment Run at $(date) ===" >> "$NFS_DEPLOY_LOG"
    tail -n 1000 "$DEPLOY_LOG" >> "$NFS_DEPLOY_LOG" 2>/dev/null || true
    echo -e "\n\n" >> "$NFS_DEPLOY_LOG"
    echo "Full deployment log archived to NFS: $NFS_DEPLOY_LOG"
fi
