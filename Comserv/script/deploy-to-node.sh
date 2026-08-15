#!/bin/bash
# deploy-to-node.sh — FULL pipeline: build (local) -> push -> pull -> run the
# pulled image on ANY node. No git involved; the container is the unit.
#
# WHY THIS SCRIPT EXISTS (root-cause of the old "prod never updates" bug):
#   The previous UI "Pull & Deploy" ran deploy.sh whose run path did
#   `docker compose pull` (a NO-OP on a build:-enabled service) + `up --force-recreate`
#   (which REBUILT from the host's stale local context and re-tagged THAT `:latest`).
#   So prod rebuilt old code and never ran the freshly-pushed digest on Docker Hub.
#   This script removes that failure mode: it builds once on the workstation,
#   pushes ONE :latest, then on each target node does `docker pull` + raw
#   `docker run` (raw run inherently executes the pulled digest — a local rebuild
#   is impossible). The same pushed image is deployed to every node identically.
#
# USAGE:
#   ./script/deploy-to-node.sh                 # build+push, deploy to default host
#   ./script/deploy-to-node.sh --host 192.168.1.198   # deploy to .198
#   ./script/deploy-to-node.sh --host production1 --host 192.168.1.198  # both
#   ./script/deploy-to-node.sh --no-build      # skip build+push, just deploy existing :latest
#   ./script/deploy-to-node.sh --no-push       # build locally, deploy, don't push
#   ./script/deploy-to-node.sh --skip-health   # deploy without the health gate
#
# Env (optional): DB_HOST, DB_PORT, DB_NAME, SYSTEM_IDENTIFIER, DOCKER_COMPOSE_FILE
set -uo pipefail

# ================== CONFIG ==================
IMAGE_NAME="${IMAGE_NAME:-shantamcsbain/comserv-web-prod:latest}"
CONTAINER_NAME="comserv2-web-prod"
OLD_CONTAINER_PREFIX="comservnode-old"
# Remote compose + service prod actually uses (kept in sync with prod's layout)
COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.prod.yml}"
COMPOSE_SVC="${COMPOSE_SVC:-web-prod}"
# Local path to the fixed deploy.sh so we can push it to the host too
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/deploy.sh"
HEALTH_ENDPOINT="http://localhost:5000/health"
LOG_FILE="/tmp/deploy-comserv-$(date +%Y%m%d-%H%M%S).log"
COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-docker-compose.prod.yml}"

# Default target host. Override with one or more --host args.
DEFAULT_HOST="production1"
HOSTS=()
DO_BUILD=1
DO_PUSH=1
DO_HEALTH=1
SSH_USER="${DEPLOY_SSH_USER:-shanta}"

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; exit 1; }

# ---- arg parse ----
while [ $# -gt 0 ]; do
    case "$1" in
        --host)       HOSTS+=("${2:-$DEFAULT_HOST}"); shift 2;;
        --no-build)   DO_BUILD=0; shift;;
        --no-push)    DO_PUSH=0; shift;;
        --skip-health) DO_HEALTH=0; shift;;
        --user)       SSH_USER="${2:-shanta}"; shift 2;;
        -h|--help)    sed -n '2,40p' "$0"; exit 0;;
        *) log "Unknown arg: $1"; exit 1;;
    esac
done
[ ${#HOSTS[@]} -eq 0 ] && HOSTS=("$DEFAULT_HOST")

log "=== Comserv node deploy === targets: ${HOSTS[*]} | build=$DO_BUILD push=$DO_PUSH health=$DO_HEALTH"

# ---- Step 1: build locally ----
if [ "$DO_BUILD" = "1" ]; then
    log "=== STEP 1: Building $IMAGE_NAME from local code ($(pwd)) ==="
    docker compose -f "$COMPOSE_FILE" build || fail "Local build failed"
    # sanity: image digest now on workstation
    LOCAL_ID=$(docker inspect --format='{{.Id}}' "$IMAGE_NAME" 2>/dev/null | cut -c1-19)
    log "Built local image: $LOCAL_ID"
fi

# ---- Step 2: push to registry ----
if [ "$DO_PUSH" = "1" ]; then
    log "=== STEP 2: Pushing $IMAGE_NAME to registry ==="
    docker push "$IMAGE_NAME" || fail "Image push failed"
    log "Pushed. Docker Hub :latest now carries this build."
fi

# ---- Step 3: deploy to each node ----
deploy_to_host() {
    local H="$1"
    log "=== STEP 3: Deploying to $H ==="

    local ssh_base="sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${SSH_USER}@${H}"
    # Verify reachability first
    $ssh_base "echo ok" >/dev/null 2>&1 || fail "Cannot SSH to $H as $SSH_USER (is sshpass env set? is the host up?)"

    # Ensure volumes exist
    $ssh_base bash -s <<'EOF' || true
        docker volume create comserv2_logs 2>/dev/null || true
        docker volume create comserv2_nfs_data 2>/dev/null || true
        docker volume create comserv2_sessions 2>/dev/null || true
        docker volume create comserv2_cache 2>/dev/null || true
        docker volume create comserv2_temp 2>/dev/null || true
        docker volume create comserv2_themes 2>/dev/null || true
        mkdir -p /opt/comserv/root/static /opt/comserv/root/LegacyStaticPages /opt/comserv/nfs 2>/dev/null || true
EOF

    # Pull the EXACT pushed image (no rebuild — compose up --no-build runs this digest)
    $ssh_base "docker pull $IMAGE_NAME" || fail "Remote image pull failed on $H"

    # Sync the fixed deploy.sh onto the host so the in-app "Pull & Deploy" button
    # also runs the corrected script (the container carries it via COPY . ., but the
    # host copy the button invokes is separate). Without this, the button would keep
    # using the old host script and rebuild locally instead of running the image.
    if [ -f "$SCRIPT_SRC" ]; then
        sshpass -e scp -o StrictHostKeyChecking=no -q "$SCRIPT_SRC" \
            "${SSH_USER}@${H}:/opt/comserv/Comserv/script/deploy.sh" 2>/dev/null \
            && $ssh_base "chmod +x /opt/comserv/Comserv/script/deploy.sh" 2>/dev/null \
            && log "Synced fixed deploy.sh to /opt/comserv/Comserv/script/deploy.sh on $H" \
            || log "⚠ Could not scp deploy.sh to $H (button path may still use old script)"
    fi

    # Pre-create the standardized named volumes the compose expects (idempotent;
    # existing volumes keep their data — we never rm volumes).
    $ssh_base bash -s <<'EOF' || true
        for v in comserv2_cache comserv2_logs comserv2_nfs_data comserv2_sessions \
                 comserv2_temp comserv2_themes comserv2_whisper_venv comserv2_cpan_cache; do
            docker volume create "$v" >/dev/null 2>&1 || true
        done
EOF

    # Stop + rename current container for rollback (single level — see cleanup below)
    local OLD_TS OLD_NAME
    OLD_TS=$(date +%Y%m%d-%H%M)
    OLD_NAME="${OLD_CONTAINER_PREFIX}-${OLD_TS}"
    if $ssh_base docker ps -q -f "name=$CONTAINER_NAME" | grep -q .; then
        log "Stopping current container on $H, renaming to $OLD_NAME"
        $ssh_base docker rename "$CONTAINER_NAME" "$OLD_NAME" 2>/dev/null || true
        $ssh_base docker stop "$OLD_NAME" 2>/dev/null || true
    fi

    # Run the PULLED image via the SAME compose prod uses (correct volumes: static
    # bind, themes, nfs, sessions, whisper venv, cpan cache). --no-build guarantees
    # compose does NOT rebuild from the host context — it runs the pulled digest.
    # This replaces the earlier hand-rolled `docker run` whose volume list drifted
    # from the compose and dropped static/CSS (the repeat "failure" cause).
    $ssh_base "cd /opt/comserv/Comserv && docker compose -f $COMPOSE_FILE up -d --force-recreate --no-build $COMPOSE_SVC" \
        || fail "Container start failed on $H (compose up --no-build)"

    # ---- Step 4: health gate ----
    if [ "$DO_HEALTH" = "1" ]; then
        log "Health check loop on $H..."
        local ok=0
        for i in $(seq 1 30); do
            if $ssh_base "curl -fs $HEALTH_ENDPOINT" >/dev/null 2>&1; then
                log "Health PASSED on $H (attempt $i)"; ok=1; break
            fi
            log "  health attempt $i on $H failed, waiting 5s..."
            sleep 5
        done
        if [ "$ok" != "1" ]; then
            log "HEALTH FAILED on $H after 30 attempts — rolling back to $OLD_NAME"
            $ssh_base bash -s <<EOF || true
                docker stop $CONTAINER_NAME 2>/dev/null || true
                docker rm $CONTAINER_NAME 2>/dev/null || true
                if docker ps -aq -f name=$OLD_NAME | grep -q .; then
                    docker start $OLD_NAME 2>/dev/null || true
                    docker rename $OLD_NAME $CONTAINER_NAME 2>/dev/null || true
                fi
EOF
            fail "Deployment to $H rolled back (health check failed)"
        fi
    fi

    # ---- Step 5: post-deploy (force DB menu + cache clear) ----
    $ssh_base docker exec "$CONTAINER_NAME" bash -c '
        perl -pi -e "s/USE_DB_MENU.*/USE_DB_MENU=1/" /opt/comserv/comserv.conf 2>/dev/null || true
        rm -rf /tmp/comserv/cache/* /cache/* 2>/dev/null || true
        echo "post-deploy done"
    ' 2>/dev/null || log "post-deploy tasks completed with warnings on $H"

    # Report the digest prod is now running
    local RUN_ID
    RUN_ID=$($ssh_base docker inspect --format='{{.Image}}' "$CONTAINER_NAME" 2>/dev/null | cut -c1-19)
    log "=== $H now running image: $RUN_ID (expected matches pushed :latest) ==="
}

for H in "${HOSTS[@]}"; do
    deploy_to_host "$H"
done

# ---- Cleanup: keep ONLY the single most-recent backup container per host ----
# We do not pile up old containers on every deploy. The just-renamed old one is
# the rollback point; anything older than that is removed.
for H in "${HOSTS[@]}"; do
    ssh_base="sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${SSH_USER}@${H}"
    $ssh_base bash -s <<EOF || true
        # List old backups sorted oldest-first, remove all but the last one
        OLD_IDS=\$(docker ps -aq -f "name=${OLD_CONTAINER_PREFIX}" --format '{{.ID}} {{.CreatedAt}}' \
            | sort -k2 | awk '{print \$1}')
        COUNT=\$(echo "\$OLD_IDS" | grep -c . || true)
        if [ "\$COUNT" -gt 1 ]; then
            echo "\$OLD_IDS" | head -n \$((COUNT-1)) | xargs -r docker rm -f 2>/dev/null || true
            echo "Cleaned \$((\$COUNT-1)) older backup container(s) on ${H}; kept 1 for rollback"
        fi
EOF
done

log "=== DEPLOY COMPLETE === targets: ${HOSTS[*]}"
log "Full log: $LOG_FILE"
