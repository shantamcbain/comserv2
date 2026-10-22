#!/usr/bin/env bash
# deploy-flow.sh — image-first deploy flow (build once, test on :4000, promote the
# SAME image to :5000, push only the tested tag, roll back by tag).
#
# Called by the deploy screen (/admin/docker/flow) or directly:
#   deploy-flow.sh <action> [--image new|TAG] [--port 5000|4000|3000]
#                  [--dest workstation|production1|both] [--apply]
# actions: plan | build | stage | promote | safe-push | rollback | tags | state
#
# DEFAULT IS PREVIEW: without --apply nothing is built, started, pushed or pulled.
# The preview prints exactly the steps --apply would run.
# Heavy lifting is delegated to deploy.sh modes (--run-image, --pull-deploy) so the
# rename-to-backup / health gate / auto-restore logic stays in one place.
set -u
REPO="shantamcsbain/comserv-web-prod"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_SH="$SCRIPT_DIR/deploy.sh"
STATE_FILE="${COMSERV_DEPLOY_STATE:-$HOME/.comserv/deploy_state.json}"
PROD1="${PROD1_HOST:-192.168.1.126}"
KNOWN_HOSTS="${COMSERV_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"

ACTION="${1:-plan}"; shift || true
IMAGE_ARG="" PORT="" DEST="" APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE_ARG="${2:-}"; shift 2 ;;
        --port)  PORT="${2:-}"; shift 2 ;;
        --dest)  DEST="${2:-}"; shift 2 ;;
        --apply) APPLY=1; shift ;;
        --dry-run|--preview) APPLY=0; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

die()  { echo "❌ $*"; exit 1; }
step() { STEPS+=("$*"); }
STEPS=()

container_for_port() {
    case "$1" in
        5000) echo "comserv2-web-prod" ;;
        4000) echo "comserv2-web-test" ;;
        3000) echo "comserv2-web-alt"  ;;
        *) return 1 ;;
    esac
}
valid_tag() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
fixed_tag() { valid_tag "$1" && [ "$1" != "latest" ] && [[ ! "$1" =~ ^backup ]]; }

# Image + health of a local container: prints "<image-ref> <health>"
container_info() {
    docker inspect --format '{{.Config.Image}} {{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null
}
tag_of() { local ref="$1"; [[ "$ref" == "$REPO:"* ]] && echo "${ref#$REPO:}"; }

ssh_prod() {
    # Host key MUST already be in known_hosts (never StrictHostKeyChecking=no).
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KNOWN_HOSTS" -i "${SSH_KEYFILE:-$HOME/.ssh/id_ed25519}" "ubuntu@$PROD1" "$@"
}

state_get() { # state_get <host> <port> current|previous
    [ -f "$STATE_FILE" ] || return 0
    python3 - "$STATE_FILE" "$1" "$2" "$3" <<'PY' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],{}).get(sys.argv[3],{}).get(sys.argv[4],"") or "")
PY
}
state_set() { # state_set <host> <port> <tag>  (current -> previous)
    mkdir -p "$(dirname "$STATE_FILE")"
    python3 - "$STATE_FILE" "$1" "$2" "$3" <<'PY'
import json,sys,os,time
f,h,p,t=sys.argv[1:]
d=json.load(open(f)) if os.path.exists(f) else {}
slot=d.setdefault(h,{}).setdefault(p,{})
if slot.get("current") and slot.get("current")!=t: slot["previous"]=slot["current"]
slot["current"]=t; slot["at"]=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())
tmp=f+".tmp"; json.dump(d,open(tmp,"w"),indent=1); os.replace(tmp,f)
PY
}

dest_hosts() {
    case "${DEST:-workstation}" in
        workstation) echo "workstation" ;;
        production1) echo "production1" ;;
        both)        echo "workstation production1" ;;
        *) die "destination must be workstation, production1 or both" ;;
    esac
}

new_tag() {
    local sha; sha=$(git -C "$APP_DIR" rev-parse --short=9 HEAD 2>/dev/null || echo nogit)
    echo "${sha}-$(date -u +%Y%m%d%H%M)"
}

# ── plan builders: each fills STEPS; run_steps executes them only with --apply ──
plan_build() {
    local tag="$1"
    local dirty; dirty=$(git -C "$APP_DIR" diff --name-only HEAD -- 2>/dev/null)
    [ -n "$dirty" ] && echo "⚠ Uncommitted tracked changes (image will be labelled +local):" && printf '    %s\n' $dirty
    step "BUILD on workstation from $(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null) → image $REPO:$tag (local only, not pushed, nothing restarted)"
    CMDS+=("build_image $tag")
}

plan_run_on() { # host port tag
    local host="$1" port="$2" tag="$3" name; name=$(container_for_port "$port") || die "port must be 5000, 4000 or 3000"
    if [ "$host" = "workstation" ]; then
        local cur; cur=$(container_info "$name")
        step "WORKSTATION :$port — start $REPO:$tag as $name. Old ${name} (${cur:-none}) is renamed bk-$name-<time> and kept for rollback; health check /health; old one restored automatically if the new one fails"
        CMDS+=("run_local $tag $name $port")
    else
        [ "$port" = "5000" ] || die "production1 only runs :5000 from this screen for now (test slots belong on the workstation)"
        step "PRODUCTION1 :5000 — pull $REPO:$tag (by tag, must already be on Docker Hub) and replace comserv2-web-prod. Old one renamed to backup; health check; auto-restore on failure"
        CMDS+=("run_prod1 $tag")
    fi
}

plan_safe_push() {
    local info ref health tag
    info=$(container_info comserv2-web-prod); ref=${info%% *}; health=${info##* }
    tag=$(tag_of "$ref")
    if [ -z "$tag" ] || ! fixed_tag "$tag"; then
        die "SAFE PUSH refused: workstation :5000 runs '${ref:-nothing}', not a fixed $REPO:<commit-time> tag. Promote a tested tag to :5000 first."
    fi
    [ "$health" = "healthy" ] || die "SAFE PUSH refused: workstation :5000 is '$health', not healthy."
    step "PUSH tested image $REPO:$tag (the one running healthy on workstation :5000) to Docker Hub, then point :latest at it. Nothing is restarted."
    CMDS+=("push_tag $tag")
    PUSHED_TAG="$tag"
}

# ── executors (only reached with --apply) ──
build_image() {
    local tag="$1" commit branch dirty
    commit=$(git -C "$APP_DIR" rev-parse --short HEAD); branch=$(git -C "$APP_DIR" rev-parse --abbrev-ref HEAD)
    git -C "$APP_DIR" diff --quiet HEAD -- || commit="${commit}+local"
    ( cd "$APP_DIR" && printf '{"branch":"%s","commit":"%s","build_date":"%s","build_host":"%s"}\n' \
        "$branch" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname -f 2>/dev/null || hostname)" > version.json )
    DOCKER_BUILDKIT=1 docker build --pull --target production \
        --build-arg GIT_COMMIT="$commit" --build-arg GIT_BRANCH="$branch" \
        --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --build-arg BUILD_HOST="$(hostname)" \
        -t "$REPO:$tag" "$APP_DIR"
}
run_local() { # tag name port
    DEPLOY_IMAGE="$REPO:$1" "$DEPLOY_SH" --run-image "$REPO:$1" "$2" "$3" && state_set workstation "$3" "$1"
}
run_prod1() {
    docker manifest inspect "$REPO:$1" >/dev/null 2>&1 || { echo "❌ $REPO:$1 is not on Docker Hub. Run Safe Push first."; return 1; }
    DEPLOY_IMAGE="$REPO:$1" "$DEPLOY_SH" --pull-deploy "$PROD1" && state_set production1 5000 "$1"
}
push_tag() {
    docker push "$REPO:$1" && docker tag "$REPO:$1" "$REPO:latest" && docker push "$REPO:latest"
}

run_steps() {
    echo
    echo "PLAN (${#STEPS[@]} step(s)):"
    local i=1 s; for s in "${STEPS[@]}"; do echo "  $i. $s"; i=$((i+1)); done
    if [ "$APPLY" != "1" ]; then
        echo
        echo "PREVIEW ONLY — nothing was built, started, pushed or pulled. Re-run with --apply to do it."
        return 0
    fi
    echo; echo "APPLYING..."
    local c; for c in "${CMDS[@]}"; do
        echo "▶ $c"
        $c || { echo "❌ Step failed: $c — stopping. Later steps were NOT run."; return 1; }
    done
    echo "✅ Done."
}
CMDS=()

case "$ACTION" in
    plan|stage)
        PORT="${PORT:-4000}"
        container_for_port "$PORT" >/dev/null || die "port must be 5000, 4000 or 3000"
        if [ -z "$IMAGE_ARG" ] || [ "$IMAGE_ARG" = "new" ]; then TAG=$(new_tag); plan_build "$TAG"
        else fixed_tag "$IMAGE_ARG" || die "image tag must be a fixed tag (not latest/backup): '$IMAGE_ARG'"; TAG="$IMAGE_ARG"
            [ "$APPLY" = 1 ] || docker image inspect "$REPO:$TAG" >/dev/null 2>&1 || echo "⚠ $REPO:$TAG is not on this workstation (will need a pull)."
        fi
        for h in $(dest_hosts); do
            if [ "$h" = "production1" ] && [ "$PORT" = "5000" ]; then
                # production1 only gets an image that ran healthy on workstation :5000
                [[ " $(dest_hosts) " == *" workstation "* ]] || echo "⚠ Sending straight to production1 skips the workstation test. Prefer destination 'both'."
                step "PUSH $REPO:$TAG to Docker Hub after workstation :5000 is healthy, then move :latest to it"
                CMDS+=("push_tag $TAG")
            fi
            plan_run_on "$h" "$PORT" "$TAG"
        done
        run_steps ;;
    promote)
        info=$(container_info comserv2-web-test); ref=${info%% *}; health=${info##* }
        TAG=$(tag_of "$ref")
        [ -n "$TAG" ] && fixed_tag "$TAG" || die "PROMOTE refused: :4000 test slot runs '${ref:-nothing}', not a fixed $REPO:<tag>."
        [ "$health" = "healthy" ] || die "PROMOTE refused: :4000 test container is '$health', not healthy."
        echo "Promoting the image that passed on :4000: $REPO:$TAG (no rebuild)."
        DEST="${DEST:-workstation}"
        for h in $(dest_hosts); do
            if [ "$h" = "production1" ]; then
                step "PUSH $REPO:$TAG to Docker Hub (after workstation :5000 is healthy with it), then move :latest"
                CMDS+=("push_tag $TAG")
            fi
            plan_run_on "$h" 5000 "$TAG"
        done
        run_steps ;;
    safe-push)
        plan_safe_push; run_steps ;;
    rollback)
        DEST="${DEST:-workstation}"
        for h in $(dest_hosts); do
            prev=$(state_get "$h" 5000 previous)
            [ -n "$prev" ] || die "ROLLBACK: no previous tag recorded for $h :5000 (state: $STATE_FILE). Use the bk-* container instead."
            plan_run_on "$h" 5000 "$prev"
        done
        run_steps ;;
    tags)
        docker images "$REPO" --format '{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}' | grep -v '<none>' | head -20 ;;
    state)
        for p in 5000 4000 3000; do
            n=$(container_for_port $p); info=$(container_info "$n"); info=${info:-absent}
            img=$(docker inspect --format '{{.Image}}' "$n" 2>/dev/null | cut -c8-19)
            note=""
            if [ -n "$img" ] && [[ "$info" == "$REPO:latest"* ]]; then
                lat=$(docker image inspect --format '{{.Id}}' "$REPO:latest" 2>/dev/null | cut -c8-19)
                [ "$img" != "$lat" ] && note=" (STALE: started from an older :latest; :latest is now $lat)"
            fi
            echo "workstation:$p $n $info${img:+ image=$img}$note current=$(state_get workstation $p current) previous=$(state_get workstation $p previous)"
        done
        echo "production1:5000 current=$(state_get production1 5000 current) previous=$(state_get production1 5000 previous)" ;;
    *) die "unknown action '$ACTION' (plan|stage|promote|safe-push|rollback|tags|state)" ;;
esac
