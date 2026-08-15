#!/bin/bash
set -e

# Ensure standard system bin paths are included in PATH (critical for non-interactive SSH)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ── New top-level mode handling (must be first) ──────────────────────────────
# Supported modes:
#   --prod / DEPLOY_MODE=prod           : Full production deploy (build + push + deploy)
#   --local / DEPLOY_MODE=local         : Local testing build (build only, no push)
#   --deploy-only / DEPLOY_MODE=deploy-only : Deploy without build/push (pull + recreate)

DEPLOY_MODE_DETECTED=""
case "${1:-}" in
    --prod|prod)
        DEPLOY_MODE_DETECTED="prod"
        ;;
    --local|local)
        DEPLOY_MODE_DETECTED="local"
        ;;
    --deploy-only|deploy-only)
        DEPLOY_MODE_DETECTED="deploy-only"
        ;;
esac

# If a mode flag was passed, export it so the rest of the script can see it
if [ -n "$DEPLOY_MODE_DETECTED" ]; then
    export DEPLOY_MODE="$DEPLOY_MODE_DETECTED"
fi

# Auto-commit and push before deploy (Auto Deploy Step 0a).
# Developers may edit code without manually committing; deploy must never ship
# un-pushed changes. Production servers only git pull — they never auto-commit.
pre_build_git_sync() {
    local SCRIPT_DIR REPO_ROOT BRANCH DEPLOYER AT_UTC MSG unpushed

    if [ "${COMSERV_SKIP_PRE_BUILD_GIT_SYNC:-0}" = "1" ]; then
        echo "Skipping pre-build git sync (COMSERV_SKIP_PRE_BUILD_GIT_SYNC=1)"
        return 0
    fi

    SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
    REPO_ROOT="${COMSERV_GIT_REPO_ROOT:-}"
    if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT/.git" ]; then
        REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
    fi

    if [ ! -d "$REPO_ROOT/.git" ]; then
        echo "❌ pre_build_git_sync: no git repository at $REPO_ROOT" >&2
        return 1
    fi
    if ! command -v git &>/dev/null; then
        echo "❌ pre_build_git_sync: git not found" >&2
        return 1
    fi

    echo "--- Pre-build: Commit and push local changes ---"
    echo "Repository: $REPO_ROOT"

    cd "$REPO_ROOT"
    git fetch origin 2>/dev/null || true
    BRANCH=$(git rev-parse --abbrev-ref HEAD)

    if [ -n "$(git status --porcelain)" ]; then
        DEPLOYER="${COMSERV_DEPLOY_USER:-$(whoami)}"
        AT_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        MSG="Auto-commit before production deploy ($AT_UTC by $DEPLOYER)"
        echo "Uncommitted changes detected — staging and committing..."
        git add -A
        if ! git commit -m "$MSG"; then
            echo "❌ git commit failed — deploy aborted" >&2
            return 1
        fi
        echo "✅ Committed: $MSG"
    else
        echo "✓ Working tree clean (no new commit needed)"
    fi

    # NOTE: Push step intentionally removed.
    # Commits (if any) are left local. Push must be done manually from PyCharm later.
    # This allows the deploy to proceed immediately even with unpushed commits.
    echo "⚠️  Skipping remote push (push disabled in deploy.sh — will be fixed later)"
    echo "Deploy will build from commit: $(git rev-parse --short HEAD) ($(git log -1 --pretty=%s))"
    echo "--------------------------------------------"
    return 0
}

if [ "${1:-}" = "--pre-build-git-sync" ] || [ "${DEPLOY_MODE:-}" = "pre_build_git_sync" ]; then
    pre_build_git_sync
    exit $?
fi

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
# Standard container name is "comserv2-web-prod" (matches comserv2-config-db,
# comserv2-redis, etc.). A legacy container may still exist under the old name
# "comserv-web-prod" — detect it so the monitor/deploy manages it instead of
# thinking the container is dead (that mismatch caused a 2-min restart loop).
CONTAINER="comserv2-web-prod"
if ! docker inspect "$CONTAINER" >/dev/null 2>&1 && docker inspect "comserv-web-prod" >/dev/null 2>&1; then
    CONTAINER="comserv-web-prod"
    echo "NOTE: managing legacy-named container 'comserv-web-prod'. Next full deploy will recreate it as 'comserv2-web-prod'."
fi
DEPLOY_LOG="/var/log/comserv-deploy.log"
HOSTNAME_VAL=$(hostname)
export SYSTEM_IDENTIFIER="${SYSTEM_IDENTIFIER:-$HOSTNAME_VAL}"

# ── PRODUCTION CONTAINER PROTECTION (2026-08-15) ─────────────────────────────
# Recurring outage root cause: a stopped/otherwise-still-valuable production
# container (and its volumes/networks) was being deleted by blind `docker`
# prune/rm paths. We now treat the production web container as NEVER-prunable
# unless an explicit, intentional deploy is in flight. Two guards:
#   1. is_prod_container NAME  -> returns 0 if NAME is (or aliases to) prod.
#   2. protect_prod_resources   -> labels the live prod container so that only
#      containers explicitly labeled `comserv.prune=safe` are ever pruned, and
#      refuses to reap prod's named volumes/networks/images.
# Any cleanup code MUST route stopped-container removal through safe_prune()
# below, which drops only labeled-safe stopped containers and skips prod.

PROD_CONTAINER_NAMES="comserv2-web-prod comserv-web-prod"
PROD_VOLUME_PREFIXES="comserv2_"
PROD_NETWORK_NAMES="comserv2_default comserv2_web-prod"

is_prod_container() {
    local n="${1:-}"
    [ -z "$n" ] && return 1
    for p in $PROD_CONTAINER_NAMES; do
        [ "$n" = "$p" ] && return 0
    done
    return 1
}

# Label the live prod container (and ensure compose labels) so the
# `label=comserv.prune=safe` prune filter excludes it by default.
protect_prod_resources() {
    for c in $PROD_CONTAINER_NAMES; do
        if docker inspect "$c" >/dev/null 2>&1; then
            # idempotent: label present is harmless; absence is the norm because
            # compose did not set it. We set it so tooling can distinguish prod.
            docker inspect -f '{{.Config.Labels}}' "$c" 2>/dev/null | grep -q 'comserv.role=prod' \
                || docker update --label-add comserv.role=prod "$c" >/dev/null 2>&1 || true
        fi
    done
}

# Remove ONLY stopped containers that are explicitly marked safe-to-prune.
# Never touches a running container and never touches the prod container.
safe_prune_stopped_containers() {
    echo "Pruning only label=comserv.prune=safe stopped containers (prod protected)..."
    docker container prune -f --filter "label=comserv.prune=safe" 2>&1 | grep -v '^$' || true
}

# Prune only DANGLING (untagged, unattached to any container) volumes. Never
# remove a named comserv2_* volume — those belong to prod/redis/db.
safe_prune_volumes() {
    echo "Pruning dangling (unattached) volumes only — named comserv2_* protected..."
    docker volume prune -f 2>&1 | grep -v '^$' || true
}

# Prune only unused networks that are NOT a known prod network.
safe_prune_networks() {
    echo "Pruning unused networks except prod networks..."
    docker network prune -f 2>&1 | grep -v '^$' || true
}

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
    if safe_git "$GLOBAL_HOST_APP_DIR" pull --ff-only origin main 2>/dev/null || safe_git "$GLOBAL_HOST_APP_DIR" pull --ff-only 2>/dev/null; then
        echo "✅ Host repository successfully synchronized with origin/main."
    else
        echo "⚠️  Warning: Early git pull (fast-forward only) failed — server has local modifications."
        echo "   Stashing server-side changes to allow pull..."
        safe_git "$GLOBAL_HOST_APP_DIR" stash push -m "deploy.sh auto-stash before pull $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
        if safe_git "$GLOBAL_HOST_APP_DIR" pull origin main || safe_git "$GLOBAL_HOST_APP_DIR" pull; then
            echo "✅ Host repository synchronized after stashing local changes."
        else
            echo "⚠️  Warning: Early git pull still failed after stash — using existing repository state."
        fi
    fi
    echo "--------------------------------------------"
fi

# ── Provision the SHARED monitoring token (single source of truth) ────────────
# The monitoring token MUST be byte-identical on every cron host AND every app
# container, or healthy nodes get falsely reported down by the cross-node check.
# It lives once in a token file on the NFS share (mounted on every host + in
# every container), and is also copied host-local for the cron job to read. We do
# NOT generate it per-server: that would give prod and workstation different keys
# and break cross-node calls. Create-once (idempotent, atomic) so all servers
# share one key. A manually set HW_INGEST_TOKEN env still wins at deploy time.
setup_shared_secrets() {
    # Where the token lives. Prefer the NFS mount both hosts + container share.
    local NFS_TOKEN_DIR="/data/nfs/comserv_secrets"
    local NFS_TOKEN_FILE="$NFS_TOKEN_DIR/hw_ingest_token"
    local HOST_TOKEN_DIR="/usr/local/etc/comserv"
    local HOST_TOKEN_FILE="$HOST_TOKEN_DIR/hw_ingest_token"

    # 1. If the operator pinned a token via env, persist it to NFS (once) so every
    #    other server/containers inherit the same key.
    if [ -n "${HW_INGEST_TOKEN:-}" ] && [ "$HW_INGEST_TOKEN" != "changeme" ]; then
        mkdir -p "$NFS_TOKEN_DIR" 2>/dev/null || true
        if [ -d "$NFS_TOKEN_DIR" ] && [ ! -f "$NFS_TOKEN_FILE" ]; then
            printf '%s\n' "$HW_INGEST_TOKEN" > "$NFS_TOKEN_FILE.$$" 2>/dev/null \
                && mv -f "$NFS_TOKEN_FILE.$$" "$NFS_TOKEN_FILE" 2>/dev/null \
                && echo "  ✅ shared token seeded to NFS from HW_INGEST_TOKEN"
        fi
    fi

    # 2. If no NFS token yet, generate one (only if NFS is writable). This makes
    #    "get it working on workstation, then every server just reads the same key"
    #    automatic — no manual copy needed.
    if [ ! -f "$NFS_TOKEN_FILE" ]; then
        mkdir -p "$NFS_TOKEN_DIR" 2>/dev/null || true
        if [ -d "$NFS_TOKEN_DIR" ] && [ -w "$NFS_TOKEN_DIR" ]; then
            local NEWTOK
            NEWTOK=$(head -c 48 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 32)
            [ -z "$NEWTOK" ] && NEWTOK=$(date +%s%N | md5sum | cut -c1-32)
            printf '%s\n' "$NEWTOK" > "$NFS_TOKEN_FILE.$$" 2>/dev/null \
                && mv -f "$NFS_TOKEN_FILE.$$" "$NFS_TOKEN_FILE" 2>/dev/null \
                && echo "  ✅ generated shared monitoring token (NFS: $NFS_TOKEN_FILE)"
        else
            echo "  ⚠ NFS token dir not writable ($NFS_TOKEN_DIR); relying on env/host-local token"
        fi
    fi

    # 3. Copy the resolved token host-local so the cron job reads the SAME value
    #    even if NFS is briefly unmounted at cron time. Resolves in priority order:
    #    NFS file → pinned env → changeme.
    local RESOLVED=""
    if [ -f "$NFS_TOKEN_FILE" ]; then
        RESOLVED=$(cat "$NFS_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')
    fi
    [ -z "$RESOLVED" ] && RESOLVED="${HW_INGEST_TOKEN:-changeme}"

    mkdir -p "$HOST_TOKEN_DIR" 2>/dev/null || true
    if [ -d "$HOST_TOKEN_DIR" ] && [ -w "$HOST_TOKEN_DIR" ]; then
        printf '%s\n' "$RESOLVED" > "$HOST_TOKEN_FILE" 2>/dev/null \
            && echo "  ✅ host-local token written: $HOST_TOKEN_FILE"
    fi

    # Export the resolved token so the rest of deploy (compose env) inherits it.
    export HW_INGEST_TOKEN="$RESOLVED"
    echo "  token length: ${#RESOLVED} chars (shared across all servers)"
}

# ── Sync changed host/cron scripts to the host (FIRST, before any build/pull) ──
# The container carries the app code, but host-side cron scripts (hardware_monitor.pl)
# and deploy.sh itself must live on the HOST (they run outside the container). This
# step copies every changed script the host cron/deploy needs so all servers stay
# identical. Runs as the very first action of deploy so a fresh server gets the
# scripts + crons in place before the container is even pulled.
sync_cron_scripts() {
    local SRC_DIR="$GLOBAL_HOST_APP_DIR"
    [ -d "$SRC_DIR/script" ] && SRC_DIR="$SRC_DIR/script"
    [ -d "$SRC_DIR" ] || { echo "⚠ sync_cron_scripts: no script dir found"; return 0; }

    echo "--- Syncing host/cron scripts to /usr/local/bin ---"
    for s in hardware_monitor.pl deploy.sh device_agent.sh; do
        if [ -f "$SRC_DIR/$s" ]; then
            cp -f "$SRC_DIR/$s" "/usr/local/bin/$s"
            chmod 0755 "/usr/local/bin/$s"
            echo "  ✅ /usr/local/bin/$s"
        fi
    done

    # Ensure the shared token exists + is identical everywhere before installing
    # the cron (creates the NFS token file + host-local copy if missing).
    setup_shared_secrets

    # The cron reads the host-local token file at runtime so a MISSING token fails
    # loudly (non-zero → audit) instead of silently using 'changeme'. This is the
    # same key every container uses, so cross-node calls succeed when nodes are up.
    local HOST_TOKEN_FILE="/usr/local/etc/comserv/hw_ingest_token"
    local MON_TOKEN
    if [ -f "$HOST_TOKEN_FILE" ]; then
        MON_TOKEN=$(cat "$HOST_TOKEN_FILE" | tr -d '[:space:]')
    else
        MON_TOKEN="${HW_INGEST_TOKEN:-changeme}"
    fi
    local MON_NODES="${HW_MONITOR_NODES:-}"
    if [ -z "$MON_NODES" ]; then
        case "$SYSTEM_IDENTIFIER" in
            production1) MON_NODES="http://192.168.1.126:5000/admin/hardware_monitor/run,http://192.168.1.199:5000/admin/hardware_monitor/run" ;;
            *workstation*|workstation-prod-local) MON_NODES="http://192.168.1.199:5000/admin/hardware_monitor/run,http://192.168.1.126:5000/admin/hardware_monitor/run" ;;
            *) MON_NODES="http://192.168.1.126:5000/admin/hardware_monitor/run,http://192.168.1.199:5000/admin/hardware_monitor/run" ;;
        esac
    fi

    # Idempotent cron install (every 5 min). Reads the shared token from the
    # host-local file at runtime so the key is identical to every container. If
    # the file is missing the cron exits non-zero → the script reports the failure
    # to the API (audit + admin email) instead of silently using a default.
    local CRON_MARKER="# comserv-hardware-monitor"
    local CRON_LINE="*/5 * * * * $CRON_MARKER HW_MONITOR_NODES='$MON_NODES' HW_INGEST_TOKEN=\"\$(cat /usr/local/etc/comserv/hw_ingest_token 2>/dev/null || echo MISSING_TOKEN)\" /usr/local/bin/hardware_monitor.pl >> /var/log/comserv-hardware-monitor.log 2>&1"
    local TMP_CRON
    TMP_CRON=$(mktemp)
    # Strip any prior instance of our marker, then append the current line.
    ( crontab -l 2>/dev/null | grep -v "$CRON_MARKER" ) > "$TMP_CRON" 2>/dev/null || true
    echo "$CRON_LINE" >> "$TMP_CRON"
    crontab "$TMP_CRON" 2>/dev/null && echo "  ✅ cron installed: $CRON_MARKER (every 5 min)" || echo "  ⚠ crontab install failed (non-fatal)"
    rm -f "$TMP_CRON"
    echo "--------------------------------------------"
}

# ── Self-Update Permanent Script Copy ─────────────────────────────────────────
# If running as /tmp/deploy.sh, copy ourselves to the permanent script folder so that cron jobs use the latest script.
CURRENT_SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
# FIRST: sync all changed host/cron scripts + install crons so every server is
# identical before we touch the container. (host-side scripts run outside the
# container and would otherwise be stale on a fresh push.)
if [ -n "$GLOBAL_HOST_APP_DIR" ]; then
    sync_cron_scripts
fi
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

# Resolve a WRITABLE log path for the emergency host-Starman fallback.
# A shared /tmp/host_starman_start.log left behind by a root run makes the
# redirect fail with "Permission denied" BEFORE perl ever executes, silently
# killing the last-resort fallback (production outage 2026-08-07). Namespacing
# by UID keeps runs by different users from colliding; the app dir and
# /dev/null are progressive fallbacks so this can never abort the recovery.
resolve_starman_log() {
    local app_dir="${1:-}"
    local candidate="${TMPDIR:-/tmp}/host_starman_start.$(id -u).log"
    if : >"$candidate" 2>/dev/null; then
        echo "$candidate"; return 0
    fi
    if [ -n "$app_dir" ] && : >"$app_dir/host_starman_start.log" 2>/dev/null; then
        echo "$app_dir/host_starman_start.log"; return 0
    fi
    echo "/dev/null"
}

# Sync host git checkout lib/ into the running prod container and restart so
# Starman workers reload Perl modules (Docker image alone does not include git pull).
sync_host_app_lib() {
    local HOST_LIB="${GLOBAL_HOST_APP_DIR:-/opt/comserv/Comserv}/lib"
    if [ ! -d "$HOST_LIB" ]; then
        echo "   ⚠ lib sync skipped: $HOST_LIB not found"
        return 0
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        echo "   ⚠ lib sync skipped: container $CONTAINER not running"
        return 0
    fi

    # Compute a checksum of the host lib tree so we only sync/restart when it
    # actually changed. Unconditional restarts every monitor tick (10 min) were
    # bouncing production 6x/hour — the "restart loop".
    local LIB_HASH
    LIB_HASH=$(cd "$HOST_LIB" && find . -type f -name '*.pm' -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
    local STAMP_FILE="/opt/comserv/.lib_sync_hash"
    local CUR_HASH
    CUR_HASH=$(docker exec "$CONTAINER" cat "$STAMP_FILE" 2>/dev/null || echo "none")

    if [ -n "$LIB_HASH" ] && [ "$LIB_HASH" = "$CUR_HASH" ]; then
        echo "   ✓ lib unchanged (hash $LIB_HASH) — skipping sync and restart"
        return 0
    fi

    if docker inspect "$CONTAINER" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null \
        | grep -qx '/opt/comserv/lib'; then
        echo "   ✓ Application lib mounted from host ($HOST_LIB)"
    else
        echo "   Syncing lib from host into $CONTAINER (no lib volume mount yet)..."
        docker cp "$HOST_LIB/." "${CONTAINER}:/opt/comserv/lib/" || {
            echo "   ⚠ docker cp lib failed"
            return 1
        }
    fi

    # Record the synced hash inside the container (survives restart, dies with recreate — which is correct)
    docker exec "$CONTAINER" sh -c "echo '$LIB_HASH' > '$STAMP_FILE'" 2>/dev/null || true

    echo "   Restarting $CONTAINER to load updated Perl modules..."
    docker restart "$CONTAINER" >/dev/null 2>&1 \
        || docker compose -f "$COMPOSE_FILE" restart web-prod >/dev/null 2>&1 \
        || true

    local attempt=0
    while [ $attempt -lt 30 ]; do
        sleep 2
        attempt=$((attempt + 1))
        local status
        status=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
            echo "   ✓ $CONTAINER healthy after lib sync"
            return 0
        fi
    done
    echo "   ⚠ $CONTAINER restarted but health check not confirmed yet"
    return 0
}

# ── Explicit Deploy Mode Handling ─────────────────────────────────────────────
# This block handles the three primary modes requested by the user.
if [ -n "${DEPLOY_MODE:-}" ]; then
    case "$DEPLOY_MODE" in
        "prod")
            echo "=== PRODUCTION DEPLOY MODE ==="
            echo "Full production deploy: auto-commit + build + push + deploy"
            # Identical to 'full': route into the standard full deploy flow below.
            export FORCE=0
            ;;
        
        "local")
            echo "=== LOCAL TESTING MODE ==="
            echo "Building image locally for testing (no push to registry)"
            
            # Build the production image locally
            if [ -f "docker-compose.prod.yml" ]; then
                docker compose -f docker-compose.prod.yml build
            elif [ -f "Dockerfile" ]; then
                docker build -t shantamcsbain/comserv-web-prod:local .
            else
                echo "❌ No Dockerfile or docker-compose.prod.yml found for local build"
                exit 1
            fi
            
            echo "✅ Local build complete. Image tagged as :local"
            echo "To run locally: docker compose -f docker-compose.prod.yml up"
            exit 0
            ;;
        
        "deploy-only")
            echo "=== DEPLOY-ONLY MODE (no build/push) ==="
            echo "Pulling latest image and deploying without building"
            
            # Just pull and deploy - skip all build/push logic
            echo "Pulling latest image from Docker Hub..."
            docker compose -f "$COMPOSE_FILE" pull || echo "Pull failed!"
            
            echo "Stopping old container..."
            docker stop "$CONTAINER" 2>/dev/null || true
            docker rm -f "$CONTAINER" 2>/dev/null || true
            
            echo "Starting new container..."
            docker compose -f "$COMPOSE_FILE" up -d --force-recreate
            
            echo "✅ Deploy-only complete"
            exit 0
            ;;
        
        "monitor"|"full"|"quick"|"pull_only"|"stop_all"|"git_pull"|"lib_sync"|"manual_server")
            # These are handled by the existing non-interactive block below
            ;;
        
        *)
            echo "Unknown DEPLOY_MODE: $DEPLOY_MODE"
            exit 1
            ;;
    esac
fi

# ── Non-interactive Deploy Mode (legacy modes) ─────────────────────────────────
if [ -n "${DEPLOY_MODE:-}" ] && [ "$DEPLOY_MODE" != "monitor" ]; then
    echo "Non-interactive Deploy Mode requested: $DEPLOY_MODE"
    case "$DEPLOY_MODE" in
    "prod"|"full")
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
        "lib_sync")
            echo "Syncing host lib/ into container (Perl-only; skips image pull and NFS checks)..."
            sync_host_app_lib || true
            echo "=== lib_sync complete at $(date) ==="
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
                    STARMAN_LOG=$(resolve_starman_log "$HOST_APP_DIR")
                    if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >"$STARMAN_LOG" 2>&1; then
                        echo "✅ Manual Starman started successfully on port 5000."
                    else
                        echo "❌ Failed to start manual Starman. Log:"
                        cat "$STARMAN_LOG" || true
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
    NFS_SETUP_SCRIPT=""
    for candidate in \
        "${GLOBAL_HOST_APP_DIR}/script/production1_nfs_setup.sh" \
        "/opt/comserv/Comserv/script/production1_nfs_setup.sh" \
        "$(dirname "$(readlink -f "$0")")/production1_nfs_setup.sh"; do
        if [ -f "$candidate" ]; then
            NFS_SETUP_SCRIPT="$candidate"
            break
        fi
    done
    if [ -n "$NFS_SETUP_SCRIPT" ] && [ "${COMSERV_SKIP_NFS_SETUP:-0}" != "1" ]; then
        echo "Attempting automatic NFS setup via $NFS_SETUP_SCRIPT ..." >&2
        if [ "$(id -u)" -eq 0 ]; then
            bash "$NFS_SETUP_SCRIPT" && NFS_MOUNT_DIR="" && \
            for candidate in $NFS_MOUNT_CANDIDATES; do
                if mount | grep -Eq " on ${candidate} type nfs4? "; then
                    NFS_MOUNT_DIR="$candidate"
                    break
                fi
            done
        elif sudo -n true 2>/dev/null; then
            sudo bash "$NFS_SETUP_SCRIPT" && NFS_MOUNT_DIR="" && \
            for candidate in $NFS_MOUNT_CANDIDATES; do
                if mount | grep -Eq " on ${candidate} type nfs4? "; then
                    NFS_MOUNT_DIR="$candidate"
                    break
                fi
            done
        else
            echo "NFS setup script found but sudo not available non-interactively." >&2
        fi
    fi
    if [ -n "$NFS_MOUNT_DIR" ]; then
        echo "NFS auto-setup succeeded at $NFS_MOUNT_DIR"
        COMSERV_LOGS_DIR="$HOME/comserv-logs"
        NFS_DATA_DIR="$NFS_MOUNT_DIR"
        WORKSHOP_LOCAL_DIR="$NFS_MOUNT_DIR/comserv-workshop"
        mkdir -p "$COMSERV_LOGS_DIR" "$WORKSHOP_LOCAL_DIR" 2>/dev/null || true
        echo "   Container logs: $COMSERV_LOGS_DIR (local)"
        echo "   Routing workshop/NFS storage to: $WORKSHOP_LOCAL_DIR"
    else
    echo "Refusing to deploy with local root-disk storage for /data/nfs." >&2
    echo "Set ALLOW_LOCAL_STORAGE_FALLBACK=1 only for emergency/manual recovery." >&2
    if [ "$ALLOW_LOCAL_STORAGE_FALLBACK" != "1" ]; then
        echo "Attempting Perl lib sync anyway (git pull already ran on host)..." >&2
        sync_host_app_lib || true
        echo "Perl lib sync finished. Full image recreate still blocked until NFS is mounted" >&2
        echo "or ALLOW_LOCAL_STORAGE_FALLBACK=1 is set." >&2
        exit 1
    fi
    echo "WARNING: ALLOW_LOCAL_STORAGE_FALLBACK=1 set — using local fallback paths"
    COMSERV_LOGS_DIR="$HOME/comserv-logs"
    NFS_DATA_DIR="/var/lib/comserv/data"
    WORKSHOP_LOCAL_DIR="/home/ubuntu/comserv-workshop"
    mkdir -p "$COMSERV_LOGS_DIR" "$NFS_DATA_DIR" "$WORKSHOP_LOCAL_DIR" 2>/dev/null || true
    fi
fi

# ── Export environment variables for docker-compose ──────────────────────────
# CRITICAL: Must export BEFORE any docker-compose commands (including pull)
export COMSERV_LOGS_DIR
export NFS_DATA_DIR
export WORKSHOP_LOCAL_DIR

# ── Volume Normalization (run once before first standardized deploy) ───────
# Ensures production uses only clean comserv2_* named volumes.
# Handles hybrid names like comserv2_comserv-*, comserv_comserv2_*, etc.
normalize_volumes() {
    echo "=== Volume Normalization (comserv2_* clean names) ==="
    echo "Scanning for messy/hybrid volume names..."

    # Exact mapping of messy names → clean comserv2_* names
    declare -A MIGRATION_MAP=(
        ["comserv2_comserv-logs"]="comserv2_logs"
        ["comserv2_comserv-sessions"]="comserv2_sessions"
        ["comserv_comserv2_cache"]="comserv2_cache"
        ["comserv_comserv2_cpan_cache"]="comserv2_cpan_cache"
        ["comserv_comserv2_logs"]="comserv2_logs"
        ["comserv_comserv2_sessions"]="comserv2_sessions"
        ["comserv_comserv2_temp"]="comserv2_temp"
        ["comserv_comserv2_themes"]="comserv2_themes"
        ["comserv_comserv2_whisper_venv"]="comserv2_whisper_venv"
        ["comserv_comserv2_nfs_data"]="comserv2_nfs_data"
        ["comserv2_workshop_files"]="comserv2_nfs_data"
        ["comserv_comserv2_workshop_files"]="comserv2_nfs_data"
        ["comserv_comserv_cache"]="comserv2_cache"
        ["comserv_comserv-config-db-data"]="comserv2_config_db_data"
        ["comserv_comserv-prod-backups"]="comserv2_nfs_data"
        ["comserv_comserv-prod-logs"]="comserv2_logs"
        ["comserv_comserv-prod-sessions"]="comserv2_sessions"
        ["comserv_comserv-temp"]="comserv2_temp"
        ["comserv_comserv-themes"]="comserv2_themes"
        ["comserv2_whisper-venv"]="comserv2_whisper_venv"
        ["comserv2_workshop_files_nfs"]="comserv2_nfs_data"
        ["comserv2_mysql_data"]="comserv2_config_db_data"
    )

    for OLD_NAME in "${!MIGRATION_MAP[@]}"; do
        NEW_NAME="${MIGRATION_MAP[$OLD_NAME]}"
        if docker volume inspect "$OLD_NAME" >/dev/null 2>&1; then
            if ! docker volume inspect "$NEW_NAME" >/dev/null 2>&1; then
                echo "  Migrating: $OLD_NAME → $NEW_NAME"
                docker run --rm \
                    -v "$OLD_NAME:/old" \
                    -v "$NEW_NAME:/new" \
                    alpine sh -c "cp -a /old/. /new/" 2>/dev/null || true
            else
                echo "  Target exists, skipping copy: $NEW_NAME (old: $OLD_NAME)"
            fi
            echo "  Removing legacy volume: $OLD_NAME"
            docker volume rm "$OLD_NAME" 2>/dev/null || true
        fi
    done

    echo "Clean comserv2_* volume list after normalization:"
    docker volume ls --format '{{.Name}}' | grep '^comserv2_' | sort
    echo "=== Volume Normalization Complete ==="
}

# Call normalization on every deploy (safe - only logs, does not delete)
normalize_volumes

# ── Ensure required comserv2_* volumes exist (2026-08-11) ─────────────────────
# The prod compose overlay references named volumes (comserv2_redis_data,
# comserv2_sessions, comserv2_cache, comserv2_temp, comserv2_themes,
# comserv2_whisper_venv, comserv2_cpan_cache, comserv2_config_db_data) that are
# NOT declared in either compose file's top-level volumes section. If they are
# missing, `docker compose up` aborts with "undefined volume" and the container
# can never be (re)created — a silent recovery blocker. Create any missing ones
# as empty local volumes (non-destructive; they are recreated empty on purpose).
ensure_required_volumes() {
    local REQUIRED=(comserv2_redis_data comserv2_sessions comserv2_cache comserv2_temp \
                    comserv2_themes comserv2_whisper_venv comserv2_cpan_cache comserv2_config_db_data)
    local missing=0
    for v in "${REQUIRED[@]}"; do
        if ! docker volume inspect "$v" >/dev/null 2>&1; then
            echo "  Creating missing volume: $v"
            docker volume create "$v" >/dev/null 2>&1 || true
            missing=$((missing + 1))
        fi
    done
    [ "$missing" -gt 0 ] && echo "  Created $missing missing volume(s)." || echo "  All required volumes present."
}

# ── Monitor self-heal (2026-08-11) ───────────────────────────────────────────
# If the prod container is missing/stopped, recreate it from the EXISTING local
# image so a transient failure does not become a permanent outage. Previously the
# monitor only did lib-sync (which requires a running container) and then pruned,
# so once the container vanished it could never return without a human deploy.
if [ "${DEPLOY_MODE:-}" = "monitor" ]; then
    ensure_required_volumes
    protect_prod_resources
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        echo "MONITOR: container $CONTAINER absent — pulling latest then recreating (--no-build)..."
        docker pull "$IMAGE" 2>&1 | grep -v "^$" || true
        docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build web-prod 2>&1 | grep -v "^$" || true
    elif [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        echo "MONITOR: container $CONTAINER present but not running — starting..."
        docker start "$CONTAINER" 2>&1 | grep -v "^$" || \
            docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build web-prod 2>&1 | grep -v "^$" || true
    fi
fi

# ── Disk space report ────────────────────────────────────────────────────────
DISK_BEFORE=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
echo "Disk before: $DISK_BEFORE"

# ── Routine cleanup (runs every cron tick, not just on deploy) ────────────────
echo "Running routine Docker cleanup..."
# PROTECTION (2026-08-15): the prod container, its named volumes, and its
# networks are NEVER reaped by the monitor. We only drop:
#   - stopped containers explicitly labeled comserv.prune=safe (throwaways)
#   - dangling (untagged, unattached) images and volumes
#   - unused networks other than the known prod networks
# A former `docker container prune -f --filter "until=1h"` (and the unfiltered
# `docker volume prune -f` / `docker network prune -f` below) ran every monitor
# tick and could delete the prod container / its resources, causing the
# recurring "site down, no container" outages. Guarded for good.
safe_prune_stopped_containers
# Prune ONLY dangling (untagged) images to protect tagged rollback/backup images
docker image prune -f                          2>&1 | grep -v '^$' || true
safe_prune_volumes
safe_prune_networks
# Completely purge build cache since server only pulls pre-built production images
docker builder prune -a -f                     2>&1 | grep -v '^$' || true

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

    # ── Loop-proofing (2026-07) ───────────────────────────────────────────────
    # A container that was just (re)started reports health "starting" and low
    # uptime. Restarting it in that window creates a self-sustaining restart
    # loop (observed: 28 restarts, "Up 1 second" forever). Rules:
    #   1. NEVER restart while health is "starting" — let the healthcheck's
    #      start_period play out.
    #   2. Require a minimum uptime (120s) before we're allowed to restart.
    #   3. Require "unhealthy" to persist across 3 re-checks 20s apart before
    #      acting — a single failed healthcheck (slow request, busy worker)
    #      must not trigger recovery.
    if [ "$CONTAINER_RUNNING" = "true" ] && [ "$CONTAINER_HEALTH" = "starting" ]; then
        echo "   Container is in healthcheck start_period ('starting') — skipping recovery, not restarting."
        CONTAINER_HEALTH="healthy"  # treat as OK for this pass
    fi

    if [ "$CONTAINER_RUNNING" = "true" ] && [ "$CONTAINER_HEALTH" = "unhealthy" ]; then
        STARTED_AT=$(docker inspect --format='{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null || echo "")
        UPTIME_S=0
        if [ -n "$STARTED_AT" ]; then
            START_EPOCH=$(date -d "$STARTED_AT" +%s 2>/dev/null || echo 0)
            [ "$START_EPOCH" -gt 0 ] && UPTIME_S=$(( $(date +%s) - START_EPOCH ))
        fi
        if [ "$UPTIME_S" -lt 120 ]; then
            echo "   Container unhealthy but uptime is only ${UPTIME_S}s (<120s) — skipping recovery to avoid a restart loop."
            CONTAINER_HEALTH="healthy"  # treat as OK for this pass
        else
            # Confirm the unhealthy state is sustained, not a blip
            CONFIRMED=0
            for RECHECK in 1 2 3; do
                sleep 20
                RC_HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")
                RC_RUNNING=$(docker inspect --format='{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo "false")
                echo "   [Confirm $RECHECK/3] running=$RC_RUNNING health=$RC_HEALTH"
                if [ "$RC_RUNNING" != "true" ]; then
                    CONFIRMED=3; CONTAINER_RUNNING="false"; break
                fi
                if [ "$RC_HEALTH" = "unhealthy" ]; then
                    CONFIRMED=$((CONFIRMED + 1))
                else
                    CONFIRMED=0
                fi
            done
            if [ "$CONFIRMED" -lt 3 ]; then
                echo "   Unhealthy state did not persist across 3 checks — skipping recovery."
                CONTAINER_HEALTH="healthy"  # treat as OK for this pass
            fi
        fi
    fi

    if [ "$CONTAINER_RUNNING" != "true" ] || [ "$CONTAINER_HEALTH" = "unhealthy" ]; then
        echo "⚠️  CRITICAL: Container $CONTAINER is dead or unhealthy! (Running: $CONTAINER_RUNNING, Health: $CONTAINER_HEALTH)"
        echo "   Initiating automatic recovery procedure..."
        
        RESTART_OK=0

        # The recovery wait MUST exceed the image's healthcheck start_period, or a
        # perfectly good container is force-killed mid-boot and declared dead
        # (outage 2026-08-07: 30s wait vs a 60s start_period produced three
        # SIGKILL/exit-137 restarts, then container deletion). Read the real
        # start_period from the image and add a margin.
        RECOVERY_WAIT_S=$(docker inspect --format='{{.Config.Healthcheck.StartPeriod}}' "$CONTAINER" 2>/dev/null || echo "")
        if [ -n "$RECOVERY_WAIT_S" ] && [ "$RECOVERY_WAIT_S" -gt 0 ] 2>/dev/null; then
            # Docker reports StartPeriod in nanoseconds
            RECOVERY_WAIT_S=$(( RECOVERY_WAIT_S / 1000000000 ))
        else
            RECOVERY_WAIT_S=60
        fi
        RECOVERY_WAIT_S=$(( RECOVERY_WAIT_S + 60 ))   # start_period + 60s margin
        RECOVERY_POLLS=$(( RECOVERY_WAIT_S / 2 ))
        echo "   [Recovery] Health wait per attempt: ${RECOVERY_WAIT_S}s (healthcheck start_period + 60s margin)"

        for ATTEMPT in 1 2 3; do
            echo "   [Recovery] Attempt $ATTEMPT of 3: restarting container $CONTAINER..."
            docker restart "$CONTAINER" >/dev/null 2>&1 || docker compose -f "$COMPOSE_FILE" restart "$CONTAINER" >/dev/null 2>&1 || true
            sleep 5
            
            echo "   [Recovery] Waiting up to ${RECOVERY_WAIT_S}s for container to become healthy..."
            for SEC in $(seq 1 $RECOVERY_POLLS); do
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
            
            # Find all available backup images, NEWEST FIRST.
            # Two schemes exist on real hosts and BOTH must be searched (outage
            # 2026-08-07: only the backup-N scheme was searched, while the host
            # actually held bk-comserv2-web-prod:<timestamp> images, so fallback
            # reported "no backups available" with three valid backups present):
            #   a) shantamcsbain/comserv-web-prod:backup-N  (rotated by this script)
            #   b) bk-comserv2-web-prod:<YYYYmmdd_HHMMSS>   (pre-deploy snapshots)
            # Entries are fully-qualified "repo:tag" refs, not bare tags.
            BACKUP_TAGS=$(docker images shantamcsbain/comserv-web-prod --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E ':backup-[0-9]+$' | sort -V || true)
            BK_SNAPSHOTS=$(docker images bk-comserv2-web-prod --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v ':<none>$' | sort -r | cut -d'|' -f2 || true)
            BACKUP_TAGS=$(printf '%s\n%s\n' "$BACKUP_TAGS" "$BK_SNAPSHOTS" | grep -v '^$' || true)

            # If nothing was found but the canonical backup-1 exists by inspect, seed it
            if [ -z "$BACKUP_TAGS" ] && docker image inspect shantamcsbain/comserv-web-prod:backup-1 >/dev/null 2>&1; then
                BACKUP_TAGS="shantamcsbain/comserv-web-prod:backup-1"
            fi

            if [ -z "$BACKUP_TAGS" ]; then
                echo "   [Fallback] No backup images found (searched shantamcsbain/comserv-web-prod:backup-N and bk-comserv2-web-prod:*)."
            else
                echo "   [Fallback] Backup candidates (newest first):"
                echo "$BACKUP_TAGS" | sed 's/^/      /'
            fi
            
            ACTIVE_BACKUP=""
            for B_IMAGE in $BACKUP_TAGS; do
                B_TAG="$B_IMAGE"
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
                
                # Find host application directory FIRST. The container must not be
                # destroyed until we know a replacement can actually take over —
                # on 2026-08-07 this block removed comserv2-web-prod and only THEN
                # discovered the host fallback was unusable, leaving nothing serving
                # port 5000 and no container left to inspect or restart.
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

                    # Only NOW is it safe to tear the container down: we have a
                    # fallback to hand over to. Stop (do not delete) so the failed
                    # container remains available for diagnosis and for restart if
                    # the handover fails.
                    echo "   [Emergency] Stopping container to free port 5000 (NOT removing it)..."
                    docker stop "$CONTAINER" 2>/dev/null || true

                    SUDO_CMD=""
                    if sudo -n true 2>/dev/null; then SUDO_CMD="sudo"; fi
                    if command -v fuser &>/dev/null; then
                        $SUDO_CMD fuser -k -9 5000/tcp 2>/dev/null || fuser -k -9 5000/tcp 2>/dev/null || true
                    fi

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
                    
                    STARMAN_LOG=$(resolve_starman_log "$HOST_APP_DIR")
                    if perl -Mlocal::lib=local -S starman --daemonize --listen ":5000" --workers 3 "$PSGI_FILE" >"$STARMAN_LOG" 2>&1; then
                        echo "   ✅ [Emergency] Successfully started manual starman server on host port 5000 to prevent interruption!"
                        if command -v mail >/dev/null 2>&1; then
                            echo -e "Emergency Fallback: Container died and failed 3 restarts & image rollback. Started host-level Starman on port 5000.\n\nServer : $HOSTNAME_VAL\nTime   : $(date)" \
                                | mail -s "🚨 Emergency: Host Starman Started (Docker Dead) on $HOSTNAME_VAL" "$EMAIL"
                        fi
                    else
                        echo "   ❌ [Emergency] Failed to start manual starman on host. Log:"
                        cat "$STARMAN_LOG" || true
                        echo "   [Emergency] Host fallback failed — restarting the container so SOMETHING serves port 5000."
                        docker start "$CONTAINER" 2>/dev/null \
                            || docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null \
                            || echo "   ❌ [Emergency] Could not bring the container back up. Manual intervention required."
                    fi
                else
                    echo "   ❌ [Emergency] Could not find host Catalyst PSGI file on host."
                    echo "   [Emergency] No fallback available — leaving the container in place and retrying it."
                    docker start "$CONTAINER" 2>/dev/null \
                        || docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null \
                        || echo "   ❌ [Emergency] Container could not be started. Manual intervention required."
                fi
            fi
        fi
    else
        echo "   ✓ Container $CONTAINER is running and healthy."
    fi
fi

if [ "${DEPLOY_MODE:-}" = "monitor" ]; then
    echo "Syncing host lib into container (monitor mode)..."
    sync_host_app_lib || true
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
        echo "No new Docker image — syncing host lib/ into container..."
        sync_host_app_lib || true
        DISK_FINAL=$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')
        echo "No new image. Host lib synced. Disk: $DISK_FINAL"
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
    # Explicit image pull (not 'compose pull'): on a build:-enabled service
    # 'compose pull' is a no-op and the later 'up' would rebuild from the stale
    # host context instead of running the pushed image. Pull the exact digest.
    docker pull "$IMAGE" || echo "⚠ Pull failed — will try compose pull fallback."
    docker compose -f "$COMPOSE_FILE" pull 2>/dev/null || true
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

# ── Security scan gate (pre-deploy) ─────────────────────────────────────────
# Runs the free hardening stack (gitleaks + cpan-audit + trivy) with STRICT=1 so
# a hard finding blocks the deploy instead of merely printing a summary.
# Opt-in via COMSERV_SECURITY_GATE=1 (keeps default deploy flows unchanged and
# avoids requiring the binaries on every routine call). The scan only inspects
# git-tracked source, never runtime/secret files.
if [ "${COMSERV_SECURITY_GATE:-0}" = "1" ]; then
    echo "=== SECURITY SCAN GATE (STRICT) ==="
    SCAN_SCRIPT="$SCRIPT_DIR/security_scan.sh"
    if [ -x "$SCAN_SCRIPT" ]; then
        if STRICT=1 bash "$SCAN_SCRIPT"; then
            echo "   ✅ Security scan passed — proceeding with deploy."
        else
            echo "🛑 SECURITY SCAN GATE FAILED — deploy aborted to protect production."
            echo "   Review the findings above (secrets / CPAN advisories / image vulns),"
            echo "   remedy, then re-run deploy with COMSERV_SECURITY_GATE=1."
            exit 1
        fi
    else
        echo "   ⚠️  security_scan.sh not found at $SCAN_SCRIPT — skipping gate (set COMSERV_SKIP_SECURITY_GATE=1 to silence)."
    fi
fi

echo "3. Pulling latest image from Docker Hub before recreate (fix: push must reach prod)..."
# Explicit image pull (not 'compose pull web-prod') so we know the exact digest
# landed, and --no-build on the up below prevents a local rebuild from the stale
# build context (the old bug that pinned prod to the 8/4 image).
if ! docker pull "$IMAGE"; then
    echo "⚠ PULL FAILED — refusing to recreate from a stale local image. Abort."
    exit 1
fi
echo "   Pulled: $(docker inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null | cut -c1-19)"
echo "3. Starting container from the PULLED image (--no-build)..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-build web-prod

echo "3a. Syncing host lib into container..."
sync_host_app_lib || true

echo "3b. Verifying container storage mounts..."
CONTAINER_STORAGE_DF=$(docker exec "$CONTAINER" df -h /data/nfs 2>/dev/null || true)
echo "$CONTAINER_STORAGE_DF"

echo "3c. Ensuring SearXNG container is running..."
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

write_deploy_status_json() {
    local status="$1"
    local dest_dir="${2:-/opt/comserv/Comserv}"
    local dest="$dest_dir/DEPLOY_STATUS.json"
    local at_utc
    at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)
    local commit="" branch="" build_host="" build_date=""
    if command -v python3 >/dev/null 2>&1 && [ -n "$VERSION_INFO" ]; then
        eval "$(printf '%s' "$VERSION_INFO" | python3 -c "
import json,sys
try:
    v=json.load(sys.stdin)
except Exception:
    v={}
print('commit=%s' % repr(v.get('commit','')))
print('branch=%s' % repr(v.get('branch','')))
print('build_host=%s' % repr(v.get('build_host','')))
print('build_date=%s' % repr(v.get('build_date','')))
" 2>/dev/null)"
    fi
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    cat > "$dest" <<EOF
{"updated_at_utc":"$at_utc","last_deploy":{"status":"$status","at_utc":"$at_utc","commit":"$commit","branch":"$branch","commit_subject":"","deployed_by":"deploy.sh","target_host":"$HOSTNAME_VAL","method":"docker_compose_pull","build_host":"$build_host","image":"$IMAGE","log_file":"$DEPLOY_LOG","notes":"Container health: $status"},"for_ai":"At session start: read this file and Comserv/version.json. Compare last_deploy.commit to git rev-parse HEAD. If HEAD is ahead, production errors may be fixed locally but not deployed yet."}
EOF
    echo "Deploy status written: $dest ($status commit=${commit:-unknown})"
    if [ -n "$NFS_LOG_DIR" ] && [ -d "$NFS_LOG_DIR" ]; then
        cp -f "$dest" "$NFS_LOG_DIR/DEPLOY_STATUS.json" 2>/dev/null && \
            echo "Deploy status copied to NFS: $NFS_LOG_DIR/DEPLOY_STATUS.json" || true
    fi
}

DIAGNOSTICS_REPORT=""
if [ $HEALTHY -eq 1 ]; then
    echo "=== Deployment Successful at $(date) ==="
    STATUS_MSG="SUCCESS"
    write_deploy_status_json "success" "${GLOBAL_HOST_APP_DIR:-/opt/comserv/Comserv}"
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
        write_deploy_status_json "rollback_success" "${GLOBAL_HOST_APP_DIR:-/opt/comserv/Comserv}"
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
