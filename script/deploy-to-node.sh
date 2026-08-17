#!/bin/bash
# deploy-to-node.sh — THIN WRAPPER (consolidation 2026-08-15).
#
# Build+push ONE image locally, then pull+run the EXACT pushed digest on every
# target node — with NO per-node rebuild. The actual pipeline lives in deploy.sh
# (canonical_deploy / canonical_deploy_to_nodes); this wrapper only parses host
# args so the result is IDENTICAL to the dashboard buttons and deploy.sh --prod.
#
# Usage:
#   ./script/deploy-to-node.sh                       # deploy to default host
#   ./script/deploy-to-node.sh --host 192.168.1.198  # add a target
#   ./script/deploy-to-node.sh --host production1 --host 192.168.1.198
#   ./script/deploy-to-node.sh --no-build            # (kept for compat) ignored — canonical always builds once
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/deploy.sh"

if [ ! -f "$DEPLOY_SH" ]; then
    echo "❌ deploy.sh not found at $DEPLOY_SH" >&2
    exit 1
fi

# Translate --host flags into positional node args for canonical_deploy_to_nodes.
NODES=()
for a in "$@"; do
    case "$a" in
        --host) shift; NODES+=("${1:-production1}");;
        --no-build|--no-push|--skip-health|--user|--verbose|-v|-h|--help)
            # compat flags: drop them; canonical enforces build+push+run uniformly
            ;;
        *) NODES+=("$a");;
    esac
done

[ ${#NODES[@]} -eq 0 ] && NODES=("production1")

echo "=== deploy-to-node.sh -> canonical multi-node deploy: ${NODES[*]} ==="
exec "$DEPLOY_SH" --deploy-to-node "${NODES[@]}"
