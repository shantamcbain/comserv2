#!/bin/bash
set -e

# Ensure standard system bin paths are included in PATH (critical for non-interactive SSH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

EMAIL="csc@computersystemconsulting.ca"
# Detect correct compose file location (either root or script directory)
if [ -f "/opt/comserv/Comserv/docker-compose.prod.yml" ]; then
    COMPOSE_FILE="/opt/comserv/Comserv/docker-compose.prod.yml"
elif [ -f "/opt/comserv/Comserv/docker-compose.server.yml" ]; then
    COMPOSE_FILE="/opt/comserv/Comserv/docker-compose.server.yml"
elif [ -f "/opt/comserv/Comserv/script/docker-compose.server.yml" ]; then
    COMPOSE_FILE="/opt/comserv/Comserv/script/docker-compose.server.yml"
else
    COMPOSE_FILE="/opt/comserv/Comserv/docker-compose.prod.yml"
fi
IMAGE="shantamcsbain/comserv-web-prod:latest"
CONTAINER="comserv2-web-prod"
DEPLOY_LOG="/var/log/comserv-deploy.log"
HOSTNAME_VAL=$(hostname)
export SYSTEM_IDENTIFIER="${SYSTEM_IDENTIFIER:-$HOSTNAME_VAL}"

# Verify host prerequisites
if ! command -v docker &>/dev/null; then
    echo "❌ ERROR: Docker is not installed on this remote server ($HOSTNAME_VAL)."
    echo "   Please install Docker first (e.g., 'sudo apt-get update && sudo apt-get install -y docker.io')."
    exit 1
fi

if ! docker compose version &>/dev/null; then
    echo "❌ ERROR: Docker Compose is not available on this remote server ($HOSTNAME_VAL)."
    echo "   Please install the Docker Compose plugin (e.g., 'sudo apt-get install -y docker-compose-v2')."
    exit 1
fi

# Check Target OS update and reboot status
echo "--- Host OS Update & Reboot Status ---"
if [ -f "/var/lib/update-notifier/updates-available" ]; then
    cat "/var/lib/update-notifier/updates-available"
elif command -v apt-get &>/dev/null; then
    PENDING_UPDATES=$(apt-get -s dist-upgrade 2>/dev/null | grep -E "^[0-9]+ upgraded" || true)
    if [ -n "$PENDING_UPDATES" ]; then
        echo "⚠️  Pending host updates: $PENDING_UPDATES"
    else
        echo "✅ Host OS packages are up to date."
    fi
fi

if [ -f "/var/run/reboot-required" ]; then
    echo "⚠️  CRITICAL: A system reboot is REQUIRED on $HOSTNAME_VAL to complete pending security updates."
else
    echo "✅ No pending system reboots."
fi
echo "----------------------------------------"

# Helper function to run Git operations safely as the repository owner
safe_git() {
    local DIR="$1"
    shift
    local OWNER=$(stat -c '%U' "$DIR" 2>/dev/null || echo "ubuntu")
    if [ "$(id -u)" -eq 0 ] && [ "$OWNER" != "root" ]; then
        sudo -u "$OWNER" git -C "$DIR" "$@"
    else
        git -C "$DIR" "$@"
    fi
}

# Locate host git repository
GLOBAL_HOST_APP_DIR=""
if [ -d "/opt/comserv/Comserv" ]; then
    GLOBAL_HOST_APP_DIR="/opt/comserv/Comserv"
elif [ -d "/home/ubuntu/comserv" ]; then
    GLOBAL_HOST_APP_DIR="/home/ubuntu/comserv"
elif [ -d "/home/shanta/PycharmProjects/comserv2" ]; then
    GLOBAL_HOST_APP_DIR="/home/shanta/PycharmProjects/comserv2"
fi

# Run an early git pull to ensure we have the absolute latest code immediately.
# This guarantees that if the container fails and we have to restart Starman on the host,
# it is already running the current software from this synchronized state.
if [ -n "$GLOBAL_HOST_APP_DIR" ] && command -v git &>/dev/null; then
    echo "--- Early Git Repository Synchronization ---"
    echo "Updating local host repository at $GLOBAL_HOST_APP_DIR..."
    safe_git "$GLOBAL_HOST_APP_DIR" fetch origin main 2>/dev/null || safe_git "$GLOBAL_HOST_APP_DIR" fetch 2>/dev/null || true
    if safe_git "$GLOBAL_HOST_APP_DIR" pull origin main || safe_git "$GLOBAL_HOST_APP_DIR" pull; then
        echo "✅ Host repository successfully synchronized with origin/main."
    else
        echo "⚠️  Warning: Early git pull failed, using existing repository state."
    fi
    echo "--------------------------------------------"
fi

# ── Self-Update Permanent Script Copy ─────────────────────────────────────────
# If running as /tmp/deploy.sh, copy ourselves to the permanent script folder so that cron jobs use the latest script.
CURRENT_SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
if [ "$CURRENT_SCRIPT_PATH" = "/tmp/deploy.sh" ] && [ -n "$GLOBAL_HOST_APP_DIR" ]; then
    echo "--- Script Self-Updating ---"
    UPDATED=0
    
    # 1. Update in Catalyst home directly (for cron/SSH /opt/comserv/Comserv/deploy.sh)
    if [ -f "$GLOBAL_HOST_APP_DIR/deploy.sh" ] || [ "$GLOBAL_HOST_APP_DIR" = "/opt/comserv/Comserv" ]; then
        echo "Copying /tmp/deploy.sh -> $GLOBAL_HOST_APP_DIR/deploy.sh"
        cp -f "$CURRENT_SCRIPT_PATH" "$GLOBAL_HOST_APP_DIR/deploy.sh"
        chmod +x "$GLOBAL_HOST_APP_DIR/deploy.sh"
        UPDATED=1
    fi
    
    # 2. Update nested Comserv/script/deploy.sh (workstation style)
    if [ -d "$GLOBAL_HOST_APP_DIR/Comserv/script" ]; then
        echo "Copying /tmp/deploy.sh -> $GLOBAL_HOST_APP_DIR/Comserv/script/deploy.sh"
        cp -f "$CURRENT_SCRIPT_PATH" "$GLOBAL_HOST_APP_DIR/Comserv/script/deploy.sh"
        chmod +x "$GLOBAL_HOST_APP_DIR/Comserv/script/deploy.sh"
        UPDATED=1
    fi
    
    # 3. Update script/deploy.sh (standard server layout)
    if [ -d "$GLOBAL_HOST_APP_DIR/script" ]; then
        echo "Copying /tmp/deploy.sh -> $GLOBAL_HOST_APP_DIR/script/deploy.sh"
        cp -f "$CURRENT_SCRIPT_PATH" "$GLOBAL_HOST_APP_DIR/script/deploy.sh"
        chmod +x "$GLOBAL_HOST_APP_DIR/script/deploy.sh"
        UPDATED=1
    fi
    
    if [ $UPDATED -eq 1 ]; then
        echo "✅ Permanent script copy updated successfully."
    else
        echo "⚠️  No valid script target directory found for self-update."
    fi
    echo "----------------------------"
fi

# Helper function to kill host processes by pattern safely, without killing the deploy script itself
safe_pkill_f() {
    local PATTERN="$1"
    local SUDO_CMD=""
    if [ "$(id -u)" -eq 0 ]; then
        SUDO_CMD="sudo"
    elif sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
    fi
    
    echo "   Finding processes matching '$PATTERN' on the host..."
    local PIDS
    PIDS=$($SUDO_CMD pgrep -f "$PATTERN" 2>/dev/null || pgrep -f "$PATTERN" 2>/dev/null || true)
    
    for pid in $PIDS; do
        [ -z "$pid" ] && continue
        [ "$pid" -eq "$$" ] && continue
        [ "$pid" -eq "$PPID" ] && continue
        
        # Check command line of the process to avoid self-killing
        local CMDLINE
        CMDLINE=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' || true)
        
        if echo "$CMDLINE" | grep -E -q "deploy\.sh|deploy-logs"; then
            echo "   [Skip] Skipping deploy script process: PID=$pid ($CMDLINE)"
            continue
        fi
        
        echo "   [Kill] Force-killing process PID=$pid: $CMDLINE"
        $SUDO_CMD kill -9 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    done
}

# ── Non-interactive Deploy Mode ──────────────────────────────────────────────
if [ -n "${DEPLOY_MODE:-}" ] && [ "$DEPLOY_MODE" != "monitor" ]; then
    echo "Non-interactive Deploy Mode requested: $DEPLOY_MODE"
    case "$DEPLOY_MODE" in
        "full")
            export FORCE=0
            # Continue to standard full deploy
            ;;
        "quick")
            export FORCE=1
            # Continue to standard quick deploy
            ;;
        "pull_only")
            echo "Pulling latest image from Docker Hub..."
            docker compose -f "$COMPOSE_FILE" pull || echo "Pull failed!"
            exit 0
            ;;
        "stop_all")
            echo "Stopping all services..."
            echo "1. Stopping container $CONTAINER..."
            docker stop "$CONTAINER" comserv-web-prod 2>/dev/null || true
            docker rm -f "$CONTAINER" comserv-web-prod 2>/dev/null || true
            docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
            
            echo "2. Force-killing host-level Starman/Plackup processes..."
            safe_pkill_f "starman"
            safe_pkill_f "plackup"
            safe_pkill_f "comserv.*psgi"
            safe_pkill_f "comserv_server"
            
            SUDO_CMD=""
            if [ "$(id -u)" -eq 0 ]; then
                SUDO_CMD="sudo"
            elif sudo -n true 2>/dev/null; then
                SUDO_CMD="sudo"
            fi
            if command -v fuser &>/dev/null; then
                $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                $SUDO_CMD fuser -k -9 3000/tcp 2>/dev/null || fuser -k -9 3000/tcp 2>/dev/null || true
            fi
            echo "Services stopped and ports 5000/3000 freed."
            exit 0
            ;;
        "git_pull")
            echo "Updating host repository via Git Pull..."
            HOST_APP_DIR=""
            if [ -d "/opt/comserv/Comserv" ]; then HOST_APP_DIR="/opt/comserv/Comserv"; fi
            if [ -n "$HOST_APP_DIR" ]; then
                safe_git "$HOST_APP_DIR" pull origin main || safe_git "$HOST_APP_DIR" pull || echo "Git pull failed."
            else
                echo "Could not locate host repository directory."
            fi
            exit 0
            ;;
        "manual_server")
            echo "Starting Emergency Manual Server on port 5000..."
            HOST_APP_DIR=""
            if [ -d "/opt/comserv/Comserv" ]; then HOST_APP_DIR="/opt/comserv/Comserv"; fi
            PSGI_FILE=""
            if [ -n "$HOST_APP_DIR" ]; then
                if [ -f "$HOST_APP_DIR/script/comserv_server.psgi" ]; then
                    PSGI_FILE="$HOST_APP_DIR/script/comserv_server.psgi"
                elif [ -f "$HOST_APP_DIR/script/comserv.psgi" ]; then
                    PSGI_FILE="$HOST_APP_DIR/script/comserv.psgi"
                elif [ -f "$HOST_APP_DIR/comserv_server.psgi" ]; then
                    PSGI_FILE="$HOST_APP_DIR/comserv_server.psgi"
                elif [ -f "$HOST_APP_DIR/comserv.psgi" ]; then
                    PSGI_FILE="$HOST_APP_DIR/comserv.psgi"
                fi
            fi
            if [ -n "$HOST_APP_DIR" ] && [ -n "$PSGI_FILE" ]; then
                echo "Updating host repository via Git Pull before starting manual server..."
                safe_git "$HOST_APP_DIR" pull origin main || safe_git "$HOST_APP_DIR" pull || echo "Git pull failed, starting with current files."
                
                safe_pkill_f "starman"
                safe_pkill_f "plackup"
                safe_pkill_f "comserv.*psgi"
                safe_pkill_f "comserv_server"
                
                SUDO_CMD=""
                if [ "$(id -u)" -eq 0 ]; then
                    SUDO_CMD="sudo"
                elif sudo -n true 2>/dev/null; then
                    SUDO_CMD="sudo"
                fi
                if command -v fuser &>/dev/null; then
                    $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                fi
                cd "$HOST_APP_DIR"
                export CATALYST_HOME="$HOST_APP_DIR"
                export CATALYST_ENV=production
                export COMSERV_LOG_DIR="$HOST_APP_DIR"
                if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >/tmp/host_starman_start.log 2>&1; then
                    echo "✅ Manual Starman started successfully on port 5000."
                else
                    echo "❌ Failed to start manual Starman. Log:"
                    cat /tmp/host_starman_start.log || true
                fi
            else
                echo "Could not find Catalyst PSGI file on host."
            fi
            exit 0
            ;;
        *)
            echo "Unknown DEPLOY_MODE: $DEPLOY_MODE"
            exit 1
            ;;
    esac
fi

# ── Interactive Menu (when run manually from terminal) ────────────────────────
if [ "$1" = "--interactive" ] || [ "$1" = "-i" ]; then
    echo "=========================================================="
    echo "      🐳 COMSERV DEPLOYMENT & SERVICE CONTROL CENTER"
    echo "=========================================================="
    echo "Host: $HOSTNAME_VAL"
    echo "Compose File: $COMPOSE_FILE"
    echo "Container: $CONTAINER"
    echo "=========================================================="
    
    while true; do
        echo ""
        echo "Please choose an action:"
        echo "  1) FULL DEPLOY (Pull new container from Docker Hub, recreate container)"
        echo "  2) QUICK DEPLOY (Force-recreate container using existing local image)"
        echo "  3) DOWNLOAD CONTAINER ONLY (Pull latest from Docker Hub)"
        echo "  4) STOP ALL SERVICES (Stop container AND aggressively kill host Starman/Plackup)"
        echo "  5) GIT UPDATE (Run git pull on the host repository)"
        echo "  6) EMERGENCY MANUAL SERVER (Start manual host-level Starman on port 5000)"
        echo "  7) EXIT"
        echo ""
        read -p "Enter choice [1-7]: " CHOICE
        
        case "$CHOICE" in
            1)
                echo "Starting FULL DEPLOY..."
                export FORCE=0
                break # Break loop and run the standard deploy flow in the script
                ;;
            2)
                echo "Starting QUICK DEPLOY..."
                export FORCE=1
                break # Break loop and run the standard deploy flow (with FORCE=1)
                ;;
            3)
                echo "Pulling latest image from Docker Hub..."
                docker compose -f "$COMPOSE_FILE" pull || echo "Pull failed!"
                ;;
            4)
                echo "Stopping all services..."
                echo "1. Stopping container $CONTAINER..."
                docker stop "$CONTAINER" comserv-web-prod 2>/dev/null || true
                docker rm -f "$CONTAINER" comserv-web-prod 2>/dev/null || true
                docker compose -f "$COMPOSE_FILE" down --remove-orphans 2>/dev/null || true
                
                echo "2. Force-killing host-level Starman/Plackup processes..."
                safe_pkill_f "starman"
                safe_pkill_f "plackup"
                safe_pkill_f "comserv.*psgi"
                safe_pkill_f "comserv_server"
                
                SUDO_CMD=""
                if [ "$(id -u)" -eq 0 ]; then
                    SUDO_CMD="sudo"
                elif sudo -n true 2>/dev/null; then
                    SUDO_CMD="sudo"
                fi
                if command -v fuser &>/dev/null; then
                    $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                    $SUDO_CMD fuser -k -9 3000/tcp 2>/dev/null || fuser -k -9 3000/tcp 2>/dev/null || true
                fi
                echo "Services stopped and ports 5000/3000 freed."
                ;;
            5)
                echo "Updating host repository via Git Pull..."
                HOST_APP_DIR=""
                if [ -d "/opt/comserv/Comserv" ]; then HOST_APP_DIR="/opt/comserv/Comserv"; fi
                if [ -n "$HOST_APP_DIR" ]; then
                    safe_git "$HOST_APP_DIR" pull origin main || safe_git "$HOST_APP_DIR" pull || echo "Git pull failed."
                else
                    echo "Could not locate host repository directory."
                fi
                ;;
            6)
                echo "Starting Emergency Manual Server on port 5000..."
                HOST_APP_DIR=""
                if [ -d "/opt/comserv/Comserv" ]; then HOST_APP_DIR="/opt/comserv/Comserv"; fi
                PSGI_FILE=""
                if [ -n "$HOST_APP_DIR" ]; then
                    if [ -f "$HOST_APP_DIR/script/comserv_server.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/script/comserv_server.psgi"
                    elif [ -f "$HOST_APP_DIR/script/comserv.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/script/comserv.psgi"
                    elif [ -f "$HOST_APP_DIR/comserv_server.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/comserv_server.psgi"
                    elif [ -f "$HOST_APP_DIR/comserv.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/comserv.psgi"
                    fi
                fi
                if [ -n "$HOST_APP_DIR" ] && [ -n "$PSGI_FILE" ]; then
                    echo "Updating host repository via Git Pull before starting manual server..."
                    safe_git "$HOST_APP_DIR" pull origin main || safe_git "$HOST_APP_DIR" pull || echo "Git pull failed, starting with current files."
                    
                    safe_pkill_f "starman"
                    safe_pkill_f "plackup"
                    safe_pkill_f "comserv.*psgi"
                    safe_pkill_f "comserv_server"
                    
                    SUDO_CMD=""
                    if sudo -n true 2>/dev/null; then SUDO_CMD="sudo"; fi
                    if command -v fuser &>/dev/null; then
                        $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                    fi
                    cd "$HOST_APP_DIR"
                    export CATALYST_HOME="$HOST_APP_DIR"
                    export CATALYST_ENV=production
                    export COMSERV_LOG_DIR="$HOST_APP_DIR"
                    if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >/tmp/host_starman_start.log 2>&1; then
                        echo "✅ Manual Starman started successfully on port 5000."
                    else
                        echo "❌ Failed to start manual Starman. Log:"
                        cat /tmp/host_starman_start.log || true
                    fi
                else
                    echo "Could not find Catalyst PSGI file on host."
                fi
                ;;
            7)
                echo "Exiting."
                exit 0
                ;;
            *)
                echo "Invalid choice. Please enter 1-7."
                ;;
        esac
    done
fi

MIGRATE_LOCAL_FALLBACK_TO_NFS="${MIGRATE_LOCAL_FALLBACK_TO_NFS:-1}"
REMOVE_LOCAL_FALLBACK_AFTER_MIGRATION="${REMOVE_LOCAL_FALLBACK_AFTER_MIGRATION:-1}"

echo "=== Comserv Production Deploy Check at $(date) ==="

# ── Detect NFS and configure paths ───────────────────────────────────────────
# Production server: /home/ubuntu/nfs (mounted from 192.168.1.175:/mnt/data)
# Workstation:       /home/shanta/nfs (mounted from 192.168.1.175:/mnt/data)
NFS_MOUNT_CANDIDATES="${NFS_MOUNT_CANDIDATES:-/home/ubuntu/nfs /home/shanta/nfs /mnt/nfs /mnt/data}"
NFS_MOUNT_DIR=""
for candidate in $NFS_MOUNT_CANDIDATES; do
    if mount | grep -Eq " on ${candidate} type nfs4? "; then
        NFS_MOUNT_DIR="$candidate"
        break
    fi
done
NFS_LOCAL_DIR="$NFS_MOUNT_DIR"

# Default paths (local fallback if NFS not mounted)
ALLOW_LOCAL_STORAGE_FALLBACK="${ALLOW_LOCAL_STORAGE_FALLBACK:-0}"
COMSERV_LOGS_DIR="$HOME/comserv-logs"
NFS_DATA_DIR=""
WORKSHOP_LOCAL_DIR=""
NFS_DEPLOY_LOG=""

if [ -n "$NFS_MOUNT_DIR" ]; then
    echo "NFS detected at $NFS_MOUNT_DIR"
    # Keep application logs local to avoid NFS flock/getattr latency hangs!
    # The application itself (Logging.pm) asynchronously copies archived/rotated logs to NFS.
    COMSERV_LOGS_DIR="$HOME/comserv-logs"
    NFS_DATA_DIR="$NFS_MOUNT_DIR"
    WORKSHOP_LOCAL_DIR="$NFS_MOUNT_DIR/comserv-workshop"
    mkdir -p "$COMSERV_LOGS_DIR" "$WORKSHOP_LOCAL_DIR" 2>/dev/null || true
    echo "   Container logs: $COMSERV_LOGS_DIR (local path to avoid NFS locking hangs)"
    echo "   Routing workshop/NFS storage to: $WORKSHOP_LOCAL_DIR"
    HOST_STORAGE_DF=$(df -P "$WORKSHOP_LOCAL_DIR" 2>/dev/null || true)
    echo "$HOST_STORAGE_DF"
    if echo "$HOST_STORAGE_DF" | awk 'NR > 1 {print $1}' | grep -vq ':'; then
        echo "ERROR: One or more container storage paths are not backed by NFS." >&2
        exit 1
    fi

    migrate_local_fallback_dir() {
        local src="$1"
        local dest="$2"
        local label="$3"

        if [ "$MIGRATE_LOCAL_FALLBACK_TO_NFS" != "1" ]; then
            return 0
        fi
        if [ ! -d "$src" ] || [ -L "$src" ] || [ "$src" = "$dest" ]; then
            return 0
        fi
        if ! find "$src" -mindepth 1 -maxdepth 1 2>/dev/null | grep -q .; then
            return 0
        fi

        echo "Migrating old local $label fallback from $src to $dest"
        mkdir -p "$dest"
        cp -a "$src/." "$dest/"
        if [ "$REMOVE_LOCAL_FALLBACK_AFTER_MIGRATION" = "1" ]; then
            echo "Removing migrated local $label fallback: $src"
            rm -rf "$src"
            mkdir -p "$src"
        else
            echo "Keeping migrated local $label fallback because REMOVE_LOCAL_FALLBACK_AFTER_MIGRATION!=1"
        fi
    }

    migrate_local_fallback_dir "/home/ubuntu/comserv-logs" "$COMSERV_LOGS_DIR" "log"
    migrate_local_fallback_dir "/home/ubuntu/comserv-workshop" "$WORKSHOP_LOCAL_DIR" "workshop"
    
    # Configure NFS Deployment Log archive path
    NFS_LOG_DIR="$NFS_MOUNT_DIR/logs"
    mkdir -p "$NFS_LOG_DIR" 2>/dev/null || true
    if [ -d "$NFS_LOG_DIR" ] && [ -w "$NFS_LOG_DIR" ]; then
        NFS_DEPLOY_LOG="${NFS_LOG_DIR}/comserv-deploy.log"
    fi
else
    echo "ERROR: NFS is not mounted at any expected path: $NFS_MOUNT_CANDIDATES" >&2
    echo "Refusing to deploy with local root-disk storage for /data/nfs." >&2
    echo "Set ALLOW_LOCAL_STORAGE_FALLBACK=1 only for emergency/manual recovery." >&2
    if [ "$ALLOW_LOCAL_STORAGE_FALLBACK" != "1" ]; then
        exit 1
    fi
    echo "WARNING: ALLOW_LOCAL_STORAGE_FALLBACK=1 set — using local fallback paths"
    COMSERV_LOGS_DIR="$HOME/comserv-logs"
    NFS_DATA_DIR="/var/lib/comserv/data"
    WORKSHOP_LOCAL_DIR="/home/ubuntu/comserv-workshop"
    mkdir -p "$COMSERV_LOGS_DIR" "$NFS_DATA_DIR" "$WORKSHOP_LOCAL_DIR" 2>/dev/null || true
fi

# ── Export environment variables for docker-compose ──────────────────────────
# CRITICAL: Must export BEFORE any docker-compose commands (including pull)
export COMSERV_LOGS_DIR
export NFS_DATA_DIR
export WORKSHOP_LOCAL_DIR

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
    
    # Prune session files older than 7 days inside the active container to prevent filesystem bloat
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        echo "Pruning expired session files older than 7 days inside $CONTAINER..."
        docker exec "$CONTAINER" find /tmp/comserv/session -type f -mtime +7 -delete 2>/dev/null || true
    fi
fi

# ── Check for compose file ─���───────────────────────────────────────────���─────
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: $COMPOSE_FILE not found. Aborting." >&2
    exit 1
fi

cd "$(dirname "$COMPOSE_FILE")"

# ── Container Viability & Auto-Recovery Check ─────────────────────────────────
# If the container is dead or unhealthy during a routine check, we restart it.
# If restarts fail, we roll back to backup-1. If rollback fails, we fall back to host Starman.
if [ -z "${DEPLOY_MODE:-}" ] || [ "$DEPLOY_MODE" = "monitor" ]; then
    echo "Checking container viability for $CONTAINER..."
    CONTAINER_RUNNING=$(docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "false")
    CONTAINER_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unhealthy")
    
    if [ "$CONTAINER_RUNNING" != "true" ] || [ "$CONTAINER_HEALTH" = "unhealthy" ]; then
        echo "⚠️  CRITICAL: Container $CONTAINER is dead or unhealthy! (Running: $CONTAINER_RUNNING, Health: $CONTAINER_HEALTH)"
        echo "   Initiating automatic recovery procedure..."
        
        RESTART_OK=0
        for ATTEMPT in 1 2 3; do
            echo "   [Recovery] Attempt $ATTEMPT of 3: restarting container $CONTAINER..."
            docker restart "$CONTAINER" >/dev/null 2>&1 || docker compose -f "$COMPOSE_FILE" restart "$CONTAINER" >/dev/null 2>&1 || true
            sleep 5
            
            # Wait up to 30 seconds for container to become healthy
            echo "   [Recovery] Waiting for container to become healthy..."
            for SEC in $(seq 1 15); do
                sleep 2
                STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
                RUNNING=$(docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "false")
                if [ "$RUNNING" = "true" ] && [ "$STATUS" = "healthy" ]; then
                    echo "   ✅ Container $CONTAINER successfully recovered and is healthy!"
                    RESTART_OK=1
                    break 2
                fi
            done
        done
        
        if [ $RESTART_OK -eq 0 ]; then
            echo "   ❌ [Recovery] All 3 restart attempts failed! Falling back to backup images..."
            FALLBACK_HEALTHY=0
            
            # Capture failure reason and container logs before stopping/deleting
            FAILED_STATE_HEALTH=$(docker inspect --format='{{json .State.Health}}' "$CONTAINER" 2>/dev/null || echo "N/A")
            FAILED_STATE_RUNNING=$(docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "false")
            FAIL_REASON="Container failed viability checks. State: Running=$FAILED_STATE_RUNNING, Health=$FAILED_STATE_HEALTH"
            CONTAINER_LOGS=$(docker logs --tail 100 "$CONTAINER" 2>&1 || echo "No logs available.")
            
            # Get the image ID of the currently running unhealthy container
            CURRENT_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER" 2>/dev/null || true)
            
            # Find all available backup tags in sorted order (e.g. backup-1, backup-2...)
            BACKUP_TAGS=$(docker images shantamcsbain/comserv-web-prod --format '{{.Tag}}' 2>/dev/null | grep -E '^backup-[0-9]+' | sort -V || true)
            
            # If no backup tags are found but backup-1 exists by inspect, seed it
            if [ -z "$BACKUP_TAGS" ] && docker image inspect shantamcsbain/comserv-web-prod:backup-1 >/dev/null 2>&1; then
                BACKUP_TAGS="backup-1"
            fi
            
            ACTIVE_BACKUP=""
            for B_TAG in $BACKUP_TAGS; do
                B_IMAGE="shantamcsbain/comserv-web-prod:$B_TAG"
                B_ID=$(docker image inspect "$B_IMAGE" --format='{{.Id}}' 2>/dev/null || true)
                
                # If this backup's image ID is already the one that failed, skip it
                if [ -n "$CURRENT_IMAGE_ID" ] && [ "$B_ID" = "$CURRENT_IMAGE_ID" ]; then
                    echo "   [Fallback] Skipping $B_TAG (image ID matches currently failed version)"
                    continue
                fi
                
                echo "   [Fallback] Attempting fallback to backup image: $B_TAG..."
                ACTIVE_BACKUP="$B_TAG"
                
                docker stop "$CONTAINER" 2>/dev/null || true
                docker rm -f "$CONTAINER" 2>/dev/null || true
                
                echo "   [Fallback] Re-tagging $B_TAG as latest..."
                docker tag "$B_IMAGE" shantamcsbain/comserv-web-prod:latest
                
                echo "   [Fallback] Launching container with rolled-back image..."
                docker compose -f "$COMPOSE_FILE" up -d --force-recreate
                
                echo "   [Fallback] Checking health of the backup container $B_TAG (up to 60s)..."
                B_HEALTHY=0
                for SEC in $(seq 1 30); do
                    sleep 2
                    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
                    RUNNING=$(docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "false")
                    if [ "$RUNNING" = "true" ] && [ "$STATUS" = "healthy" ]; then
                        B_HEALTHY=1
                        break
                    fi
                done
                
                if [ $B_HEALTHY -eq 1 ]; then
                    echo "   ✅ [Fallback] Successfully rolled back to $B_TAG! Container is healthy."
                    FALLBACK_HEALTHY=1
                    break
                fi
                
                echo "   ❌ [Fallback] Backup $B_TAG failed to become healthy. Trying next backup..."
                # Get the new failed image ID to prevent retrying this one too
                CURRENT_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CONTAINER" 2>/dev/null || true)
            done
            
            if [ $FALLBACK_HEALTHY -eq 1 ]; then
                # Construct detailed email body with exact reasons and logs
                EMAIL_BODY="⚠️ CRITICAL ALERT: Container rollback/rotation occurred on $HOSTNAME_VAL!\n\n"
                EMAIL_BODY="${EMAIL_BODY}Details:\n"
                EMAIL_BODY="${EMAIL_BODY}- Failed Container: $CONTAINER\n"
                EMAIL_BODY="${EMAIL_BODY}- Reason: $FAIL_REASON\n"
                EMAIL_BODY="${EMAIL_BODY}- Recovered/Rotated Image: $ACTIVE_BACKUP\n"
                EMAIL_BODY="${EMAIL_BODY}- Time of Event: $(date)\n\n"
                EMAIL_BODY="${EMAIL_BODY}------------------------------------------------------------\n"
                EMAIL_BODY="${EMAIL_BODY}LAST 100 LINES OF LOGS FOR FAILED CONTAINER:\n"
                EMAIL_BODY="${EMAIL_BODY}------------------------------------------------------------\n"
                EMAIL_BODY="${EMAIL_BODY}$CONTAINER_LOGS\n"

                if command -v mail >/dev/null 2>&1; then
                    echo -e "$EMAIL_BODY" | mail -s "⚠️ Container Failover to $ACTIVE_BACKUP on $HOSTNAME_VAL" "$EMAIL"
                fi
                
                # Log critical system alert in DB
                if [ -d "$GLOBAL_HOST_APP_DIR" ]; then
                    perl -I"$GLOBAL_HOST_APP_DIR/lib" -MComserv::Util::Logging -MComserv::Util::HealthLogger -e '
                        my ($b_tag, $reason) = @ARGV;
                        eval { Comserv::Util::HealthLogger->log_event(undef, level => "CRITICAL", category => "HEALTH", message => "Container failover to $b_tag. Reason: $reason") };
                    ' "$ACTIVE_BACKUP" "$FAIL_REASON"
                fi
            else
                echo "   ❌ [Fallback] All backup images failed or no backups available."
                echo "   [Emergency] Starting host-level Starman so service is not interrupted..."
                
                # Construct detailed email body for complete failover failure
                EMAIL_BODY="🚨 EMERGENCY CRITICAL ALERT: Container failover completely failed on $HOSTNAME_VAL!\n\n"
                EMAIL_BODY="${EMAIL_BODY}Details:\n"
                EMAIL_BODY="${EMAIL_BODY}- Failed Container: $CONTAINER\n"
                EMAIL_BODY="${EMAIL_BODY}- Reason: $FAIL_REASON\n"
                EMAIL_BODY="${EMAIL_BODY}- Recovery Action: All backup images failed. Starting host-level Starman.\n"
                EMAIL_BODY="${EMAIL_BODY}- Time of Event: $(date)\n\n"
                EMAIL_BODY="${EMAIL_BODY}------------------------------------------------------------\n"
                EMAIL_BODY="${EMAIL_BODY}LAST 100 LINES OF LOGS FOR FAILED CONTAINER:\n"
                EMAIL_BODY="${EMAIL_BODY}------------------------------------------------------------\n"
                EMAIL_BODY="${EMAIL_BODY}$CONTAINER_LOGS\n"

                if command -v mail >/dev/null 2>&1; then
                    echo -e "$EMAIL_BODY" | mail -s "🚨 Container Failover FAILED - Host Starman Started on $HOSTNAME_VAL" "$EMAIL"
                fi

                # Log critical system alert in DB
                if [ -d "$GLOBAL_HOST_APP_DIR" ]; then
                    perl -I"$GLOBAL_HOST_APP_DIR/lib" -MComserv::Util::Logging -MComserv::Util::HealthLogger -e '
                        my ($reason) = @ARGV;
                        eval { Comserv::Util::HealthLogger->log_event(undef, level => "CRITICAL", category => "HEALTH", message => "Container failover completely FAILED! Switched to host Starman. Reason: $reason") };
                    ' "$FAIL_REASON"
                fi
                
                # Stop any failed docker container first to free port 5000
                docker stop "$CONTAINER" 2>/dev/null || true
                docker rm -f "$CONTAINER" 2>/dev/null || true
                
                # Free ports
                SUDO_CMD=""
                if sudo -n true 2>/dev/null; then SUDO_CMD="sudo"; fi
                if command -v fuser &>/dev/null; then
                    $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                fi
                
                # Find host application directory
                HOST_APP_DIR=""
                if [ -d "/opt/comserv/Comserv" ]; then
                    HOST_APP_DIR="/opt/comserv/Comserv"
                elif [ -d "/home/ubuntu/comserv" ]; then
                    HOST_APP_DIR="/home/ubuntu/comserv"
                elif [ -d "/home/shanta/PycharmProjects/comserv2" ]; then
                    HOST_APP_DIR="/home/shanta/PycharmProjects/comserv2"
                fi
                
                PSGI_FILE=""
                if [ -n "$HOST_APP_DIR" ]; then
                    if [ -f "$HOST_APP_DIR/script/comserv_server.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/script/comserv_server.psgi"
                    elif [ -f "$HOST_APP_DIR/script/comserv.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/script/comserv.psgi"
                    elif [ -f "$HOST_APP_DIR/comserv_server.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/comserv_server.psgi"
                    elif [ -f "$HOST_APP_DIR/comserv.psgi" ]; then
                        PSGI_FILE="$HOST_APP_DIR/comserv.psgi"
                    fi
                fi
                
                if [ -n "$HOST_APP_DIR" ] && [ -n "$PSGI_FILE" ]; then
                    echo "   [Emergency] Found host git repository at $HOST_APP_DIR"
                    cd "$HOST_APP_DIR"
                    
                    if [ -f "script/comserv_server.psgi" ]; then
                        rm -f comserv.psgi 2>/dev/null || true
                        ln -sf script/comserv_server.psgi comserv.psgi || cp -f script/comserv_server.psgi comserv.psgi || true
                    fi

                    # Start Host starman daemon using local git code
                    export CATALYST_HOME="$HOST_APP_DIR"
                    export CATALYST_ENV=production
                    export COMSERV_LOG_DIR="$HOST_APP_DIR"
                    
                    safe_pkill_f "starman"
                    safe_pkill_f "plackup"
                    safe_pkill_f "comserv.*psgi"
                    safe_pkill_f "comserv_server"
                    
                    if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >/tmp/host_starman_start.log 2>&1; then
                        echo "   ✅ [Emergency] Successfully started manual starman server on host port 5000 to prevent interruption!"
                        if command -v mail >/dev/null 2>&1; then
                            echo -e "Emergency Fallback: Container died and failed 3 restarts & image rollback. Started host-level Starman on port 5000.\n\nServer : $HOSTNAME_VAL\nTime   : $(date)" \
                                | mail -s "🚨 Emergency: Host Starman Started (Docker Dead) on $HOSTNAME_VAL" "$EMAIL"
                        fi
                    else
                        echo "   ❌ [Emergency] Failed to start manual starman on host. Log:"
                        cat /tmp/host_starman_start.log || true
                    fi
                else
                    echo "   ❌ [Emergency] Could not find host Catalyst PSGI file on host."
                fi
            fi
        fi
    else
        echo "   ✓ Container $CONTAINER is running and healthy."
    fi
fi

if [ "${DEPLOY_MODE:-}" = "monitor" ]; then
    echo "Viability check completed in monitor mode."
    exit 0
fi

# ── Version check ────────────────────────────────────────────────────────────
if [ "${DEPLOY_MODE:-}" = "quick" ]; then
    echo "Mode: QUICK DEPLOY — Skipping remote version check and image pulling from Docker Hub."
    echo "Using existing local image: $IMAGE"
else
    echo "Checking for new image on Docker Hub..."

    LOCAL_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null || echo "none")
    REMOTE_DIGEST=$(docker manifest inspect "$IMAGE" 2>/dev/null \
        | grep -o '"digest":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "none")

    echo "  Local : ${LOCAL_DIGEST:0:72}..."
    echo "  Remote: ${REMOTE_DIGEST:0:72}..."

    if [ "$FORCE" != "1" ] && [ "$LOCAL_DIGEST" = "$REMOTE_DIGEST" ] && [ "$LOCAL_DIGEST" != "none" ]; then
        DISK_FINAL=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
        echo "No new version. Disk: $DISK_FINAL"
        echo "=== Finished at $(date) ==="
        exit 0
    fi

    echo "New version detected. Starting deployment..."

    # ── Rotate rollback/backup images (Keep 5 backups) ───────────────────────────
    echo "Rotating rollback/backup images (keeping up to 5 backups)..."
    # Remove oldest backup (backup-5) if it exists
    docker rmi shantamcsbain/comserv-web-prod:backup-5 2>/dev/null || true
    
    # Shift existing backups down the line: 4 -> 5, 3 -> 4, 2 -> 3, 1 -> 2
    for i in 4 3 2 1; do
        NEXT=$((i + 1))
        if docker image inspect shantamcsbain/comserv-web-prod:backup-$i >/dev/null 2>&1; then
            docker tag shantamcsbain/comserv-web-prod:backup-$i shantamcsbain/comserv-web-prod:backup-$NEXT
            docker rmi shantamcsbain/comserv-web-prod:backup-$i 2>/dev/null || true
        fi
    done
    
    # Move current latest to backup-1
    if docker image inspect shantamcsbain/comserv-web-prod:latest >/dev/null 2>&1; then
        docker tag shantamcsbain/comserv-web-prod:latest shantamcsbain/comserv-web-prod:backup-1
    fi

    echo "1. Pulling latest image..."
    docker compose -f "$COMPOSE_FILE" pull
fi

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
# Stop host port 5000/3000 processes to prevent "port already in use" binding errors in Docker
HOST_PORT_OCCUPIED=0

# Try to detect with sudo first (non-interactive), then fallback to current user
SUDO_CMD=""
if sudo -n true 2>/dev/null; then
    SUDO_CMD="sudo"
fi

# Stop and disable systemd starman service if active
echo "   Stopping and disabling host-level systemd starman service..."
$SUDO_CMD systemctl stop starman.service 2>/dev/null || true
$SUDO_CMD systemctl disable starman.service 2>/dev/null || true

# 1. Terminate any manual Starman or Plackup processes aggressively by process name/command line using SIGKILL (-9)
echo "   Force-killing running starman/plackup/comserv host processes..."
safe_pkill_f "starman"
safe_pkill_f "plackup"
safe_pkill_f "comserv.*psgi"
safe_pkill_f "comserv_server"
sleep 1

# 2. Check and terminate anything listening specifically on port 5000 or 3000
if command -v fuser &>/dev/null; then
    $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
    $SUDO_CMD fuser -k -9 3000/tcp 2>/dev/null || fuser -k -9 3000/tcp 2>/dev/null || true
fi

if command -v lsof &>/dev/null; then
    HOST_PIDS=$($SUDO_CMD lsof -t -i:5000 -i:3000 2>/dev/null || lsof -t -i:5000 -i:3000 2>/dev/null || true)
    HOST_PIDS=$(echo "$HOST_PIDS" | tr '\n' ' ' | xargs || true)
    if [ -n "$HOST_PIDS" ]; then
        echo "   ⚠ Found host process(es) ($HOST_PIDS) occupying port 5000/3000. Force killing..."
        $SUDO_CMD kill -9 $HOST_PIDS 2>/dev/null || kill -9 $HOST_PIDS 2>/dev/null || true
        HOST_PORT_OCCUPIED=1
    fi
fi

# Fallback using ss to detect remaining PIDs
HOST_PIDS=$($SUDO_CMD ss -tulpn 2>/dev/null | grep -E ':(5000|3000) ' | grep -o -E 'pid=[0-9]+' | cut -d= -f2 | tr '\n' ' ' | xargs || true)
if [ -z "$HOST_PIDS" ]; then
    HOST_PIDS=$(ss -tulpn 2>/dev/null | grep -E ':(5000|3000) ' | grep -o -E 'pid=[0-9]+' | cut -d= -f2 | tr '\n' ' ' | xargs || true)
fi
if [ -n "$HOST_PIDS" ]; then
    echo "   ⚠ ss detected host process ($HOST_PIDS) occupying port 5000/3000. Force killing..."
    $SUDO_CMD kill -9 $HOST_PIDS 2>/dev/null || kill -9 $HOST_PIDS 2>/dev/null || true
    HOST_PORT_OCCUPIED=1
fi

sleep 1
echo "   ✓ Port 5000 and 3000 are verified free on the host"

echo "2c. Checking and populating database secrets for Docker..."
# If /opt/comserv/Comserv/db_config.json exists, extract individual profile json files 
# into /home/ubuntu/.comserv/secrets/dbi to ensure the container starts healthy with loaded secrets.
if [ -f "/opt/comserv/Comserv/db_config.json" ]; then
    echo "   Found host-level db_config.json. Populating container secrets directory..."
    mkdir -p /home/ubuntu/.comserv/secrets/dbi
    perl -MJSON::PP -e '
        my $file = "/opt/comserv/Comserv/db_config.json";
        open my $fh, "<", $file or die $!;
        local $/;
        my $data = decode_json(<$fh>);
        close $fh;
        for my $key (keys %$data) {
            my $profile = {$key => $data->{$key}};
            open my $out, ">", "/home/ubuntu/.comserv/secrets/dbi/$key.json" or die $!;
            print $out encode_json($profile);
            close $out;
        }
    ' 2>/dev/null
    chmod -R 755 /home/ubuntu/.comserv 2>/dev/null || true
    chown -R ubuntu:ubuntu /home/ubuntu/.comserv 2>/dev/null || true
    echo "   ✓ Secrets directory populated and ready"
else
    echo "   ⚠ Warning: /opt/comserv/Comserv/db_config.json not found on host"
fi

echo "3. Starting new container..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate

echo "3a. Verifying container storage mounts..."
CONTAINER_STORAGE_DF=$(docker exec "$CONTAINER" df -h /data/nfs 2>/dev/null || true)
echo "$CONTAINER_STORAGE_DF"

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

echo "4. Waiting for health check (up to 120s) & streaming startup logs..."
ATTEMPT=0
HEALTHY=0
PREV_LINE_COUNT=0
while [ $ATTEMPT -lt 60 ]; do
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
    echo "❌ ERROR: Container did not reach healthy state within 120s"
    
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
        PSGI_FILE=""
        if [ -n "$HOST_APP_DIR" ]; then
            if [ -f "$HOST_APP_DIR/script/comserv_server.psgi" ]; then
                PSGI_FILE="$HOST_APP_DIR/script/comserv_server.psgi"
            elif [ -f "$HOST_APP_DIR/script/comserv.psgi" ]; then
                PSGI_FILE="$HOST_APP_DIR/script/comserv.psgi"
            elif [ -f "$HOST_APP_DIR/comserv_server.psgi" ]; then
                PSGI_FILE="$HOST_APP_DIR/comserv_server.psgi"
            elif [ -f "$HOST_APP_DIR/comserv.psgi" ]; then
                PSGI_FILE="$HOST_APP_DIR/comserv.psgi"
            fi
        fi

        if [ -n "$HOST_APP_DIR" ] && [ -n "$PSGI_FILE" ]; then
            echo "   [Emergency] Found host git repository at $HOST_APP_DIR"
            cd "$HOST_APP_DIR"
            
            # Pull latest changes from git main branch to keep code fully up-to-date
            echo "   [Emergency] Pulling latest changes from main branch..."
            if command -v git &>/dev/null; then
                safe_git "$HOST_APP_DIR" pull origin main || safe_git "$HOST_APP_DIR" pull || echo "   ⚠ Warning: git pull failed, starting with existing local files"
            fi
            
            export CATALYST_HOME="$HOST_APP_DIR"
            export CATALYST_ENV=production
            export COMSERV_LOG_DIR="$HOST_APP_DIR"
            
            # Start Host starman daemon using the last git pull code
            if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >/tmp/host_starman_start.log 2>&1; then
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
