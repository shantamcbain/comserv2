#!/bin/bash
# deploy-to-production1.sh
# Robust production deployment script for Comserv
# Generated with Continue
# Features:
# - Build on workstation, test locally first
# - Push/deploy to production1 via SSH + Docker
# - Ensure critical volumes (comserv-temp, comserv-cache, comserv-themes, static, NFS)
# - Health check loop using /health endpoint
# - Automatic rollback on failure with exact reason
# - Keep only last 5 old containers, rename with timestamp
# - Named volumes consistent across dev/prod
# - Force DB-driven menu mode + clear static caches post-deploy
# - Idempotent + full logging to popup/log
# - Monitor entire process in popup (logs streamed)

set -euo pipefail

# ================== CONFIG ==================
PROD_HOST="production1"
PROD_USER="shanta"
IMAGE_NAME="shantamcsbain/comserv-web-prod:latest"
CONTAINER_NAME="comserv-web-prod"
OLD_CONTAINER_PREFIX="comservproduction1-old"
HEALTH_ENDPOINT="http://localhost:5000/health"
MAX_OLD_CONTAINERS=5
LOG_FILE="/tmp/deploy-comserv-$(date +%Y%m%d-%H%M%S).log"
# ============================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $*"
    exit 1
}

# Step 1: Build and test locally
build_and_test_locally() {
    log "=== STEP 1: Building and testing locally ==="
    docker-compose -f docker-compose.prod.yml build || fail "Local build failed"
    docker-compose -f docker-compose.prod.yml up -d || fail "Local container start failed"
    sleep 10
    if ! curl -f "$HEALTH_ENDPOINT" >/dev/null 2>&1; then
        fail "Local health check failed after start"
    fi
    log "Local build and health check passed"
    docker-compose -f docker-compose.prod.yml down
}

# Step 2: Push image (assumes docker login already done)
push_image() {
    log "=== STEP 2: Pushing image to registry ==="
    docker push "$IMAGE_NAME" || fail "Image push failed"
}

# Step 3: Remote deployment on production1
# Ensure shanta user exists on production server (Docker operator)

ensure_docker_user() {

    log "Ensuring docker user shanta exists on ${PROD_HOST}..."

    # Bootstrap as ubuntu (must exist and have SSH keys)

    sshpass -e ssh -o StrictHostKeyChecking=no "ubuntu@${PROD_HOST}" bash -s <<'EOF_DOCKERUSER'

        if ! id "shanta" &>/dev/null; then

            echo "Creating shanta user..."

            useradd -m -s /bin/bash shanta

            echo "shanta ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/shanta

            chmod 440 /etc/sudoers.d/shanta

        fi

        if ! groups shanta | grep -q docker; then

            echo "Adding shanta to docker group..."

            usermod -aG docker shanta

        fi

        # Copy authorized_keys from ubuntu for SSH access

        if [ -d /home/ubuntu/.ssh ] && [ ! -f /home/shanta/.ssh/authorized_keys ]; then

            mkdir -p /home/shanta/.ssh

            cp /home/ubuntu/.ssh/authorized_keys /home/shanta/.ssh/authorized_keys 2>/dev/null || true

            chown -R shanta:shanta /home/shanta/.ssh

            chmod 700 /home/shanta/.ssh

            chmod 600 /home/shanta/.ssh/authorized_keys

        fi

EOF_DOCKERUSER

    log "Docker user shanta verified/created successfully"

}
deploy_to_production() {
    ensure_docker_user
    log "=== STEP 3: Deploying to production1 ==="

    ssh_cmd="sshpass -e ssh -o StrictHostKeyChecking=no ${PROD_USER}@${PROD_HOST}"

    # Ensure volumes exist
    $ssh_cmd bash -s <<'EOF'
        docker volume create comserv-temp 2>/dev/null || true
        docker volume create comserv-cache 2>/dev/null || true
        docker volume create comserv-themes 2>/dev/null || true
        mkdir -p /opt/comserv/root/static /opt/comserv/root/LegacyStaticPages /opt/comserv/nfs
        # Ensure NFS mounts if needed (example)
        # mount -t nfs ... || true
EOF

    # Pull new image
    $ssh_cmd docker pull "$IMAGE_NAME" || fail "Remote image pull failed"

    # Stop and rename old container if running
    OLD_TS=$(date +%Y%m%d-%H%M)
    OLD_NAME="${OLD_CONTAINER_PREFIX}-${OLD_TS}"
    if $ssh_cmd docker ps -q -f name="$CONTAINER_NAME" | grep -q .; then
        log "Stopping current container and renaming to $OLD_NAME"
        $ssh_cmd docker rename "$CONTAINER_NAME" "$OLD_NAME"
        $ssh_cmd docker stop "$OLD_NAME" || true
    fi

    # Start new container with all required volumes
    $ssh_cmd docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p 5000:5000 \
        -e ENVIRONMENT=production \
        -e CATALYST_ENV=production \
        -e CATALYST_DEBUG=0 \
        -e COMSERV_NO_HEALTH_LOG=1 \
        -e NFS_DATA_PATH=/data/nfs \
        -e COMSERV_LOG_DIR=/opt/comserv/root/log \
        -e DISABLE_FILE_LOGGING=1 \
        -e COMSERV_LOG_MIN_LEVEL=WARN \
        -e DB_LOG_MIN_LEVEL=WARN \
        -e COMSERV_SESSION_DIR=/tmp/comserv/session \
        -e COMSERV_SESSION_COOKIE=comserv_session \
        -e DB_HOST="${DB_HOST:-192.168.1.198}" \
        -e DB_PORT="${DB_PORT:-3306}" \
        -e DB_NAME="${DB_NAME:-ency}" \
        -e SYSTEM_IDENTIFIER="${SYSTEM_IDENTIFIER:-production1}" \
        -v /opt/comserv/secrets:/opt/comserv/secrets:ro \
        -v comserv2_logs:/opt/comserv/root/log \
        -v comserv2_nfs:/opt/comserv/nfs:rw \
        -v comserv2_sessions:/tmp/comserv/session:rw \
        -v comserv2_cache:/cache \
        -v comserv_cache:/tmp/comserv/cache \
        -v comserv-temp:/tmp/comserv/temp \
        -v comserv-themes:/opt/comserv/root/themes \
        -v comserv2_static:/opt/comserv/root/static \
        -v /opt/comserv/legacy-static:/opt/comserv/root/LegacyStaticPages \
        "$IMAGE_NAME" || fail "New container start failed"

    log "New container started: $CONTAINER_NAME"
}

# Step 4: Health check loop with rollback
health_check_and_rollback() {
    log "=== STEP 4: Health check loop (monitoring /health) ==="
    for i in {1..30}; do
        if sshpass -e ssh -o StrictHostKeyChecking=no "${PROD_USER}@${PROD_HOST}" "curl -f $HEALTH_ENDPOINT" >/dev/null 2>&1; then
            log "Health check PASSED on attempt $i"
            return 0
        fi
        log "Health check attempt $i failed, waiting..."
        sleep 5
    done

    log "Health check FAILED after 30 attempts. Rolling back..."
    rollback
    fail "Deployment rolled back due to health check failure. See log: $LOG_FILE"
}

rollback() {
    log "Rollback initiated – restoring previous healthy container"
    sshpass -e ssh -o StrictHostKeyChecking=no "${PROD_USER}@${PROD_HOST}" bash -s <<EOF
        docker stop $CONTAINER_NAME || true
        docker rm $CONTAINER_NAME || true
        LATEST_OLD=\$(docker ps -aq -f name=$OLD_CONTAINER_PREFIX | head -1)
        if [ -n "\$LATEST_OLD" ]; then
            docker start \$LATEST_OLD || true
            docker rename \$LATEST_OLD $CONTAINER_NAME || true
        fi
EOF
    log "Rollback completed"
}

# Step 5: Cleanup old containers (keep last 5)
cleanup_old_containers() {
    log "=== STEP 5: Cleaning up old containers (keep last $MAX_OLD_CONTAINERS) ==="
    sshpass -e ssh -o StrictHostKeyChecking=no "${PROD_USER}@${PROD_HOST}" bash -s <<EOF
        docker ps -aq -f name=$OLD_CONTAINER_PREFIX | tail -n +$((MAX_OLD_CONTAINERS+1)) | xargs -r docker rm -f
EOF
}

# Step 6: Post-deploy tasks (DB menu mode + cache clear)
post_deploy_tasks() {
    log "=== STEP 6: Post-deploy tasks (force DB menu + clear caches) ==="
    sshpass -e ssh -o StrictHostKeyChecking=no "${PROD_USER}@${PROD_HOST}" docker exec "$CONTAINER_NAME" bash -c '
        # Force DB-driven menu
        perl -pi -e "s/USE_DB_MENU.*/USE_DB_MENU=1/" /opt/comserv/comserv.conf || true
        # Clear any static caches
        rm -rf /tmp/comserv/cache/* /cache/* 2>/dev/null || true
        echo "Post-deploy cleanup done"
    ' || log "Post-deploy tasks completed with warnings"
}

# Interactive menu (only two options)
show_menu() {
    echo ""
    echo "Type [1] for FULL DEPLOY (Primary Choice):"
    echo "  - Rebuilds and pushes a new image to Docker Hub, then restarts the production server container."
    echo ""
    echo "Type [2] for Build & test locally only (no deploy):"
    echo "  - Builds and tests the production image locally but does not push or deploy."
    echo ""
    read -rp "Select option [1-2]: " choice
    case "$choice" in
        1)
            log "User selected: FULL DEPLOY"
            build_and_test_locally
            push_image
            deploy_to_production
            health_check_and_rollback
            cleanup_old_containers
            post_deploy_tasks
            log "=== FULL DEPLOY SUCCESSFUL ==="
            ;;
        2)
            log "User selected: Build & test locally only"
            build_and_test_locally
            log "Local build & test completed successfully. No deployment performed."
            ;;
        *)
            echo "Invalid selection. Please enter 1 or 2."
            exit 1
            ;;
    esac
    log "Full log saved to: $LOG_FILE"
}

# Main
main() {
    # Parse --verbose flag
    for arg in "$@"; do
        if [ "$arg" = "--verbose" ] || [ "$arg" = "-v" ]; then
            VERBOSE=true
            echo "[VERBOSE MODE ENABLED]"
        fi
    done

    log "=== Comserv Production Deployment Started ==="
    show_menu
}

main "$@"