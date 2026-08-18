#!/bin/bash
# deploy-to-production1.sh — THIN WRAPPER (consolidation 2026-08-15).
#
# This script no longer contains its own deploy logic. It now delegates to the
# SINGLE canonical pipeline in deploy.sh (canonical_deploy) so the result is
# IDENTICAL to every other entry point (dashboard buttons, deploy-to-node.sh,
# deploy.sh --prod). The "one build, one push, one pull, one deploy" rule is
# enforced in one place.
#
# Usage:
#   ./deploy-to-production1.sh            # build+push locally, deploy to prod1
#   ./deploy-to-production1.sh --host X   # deploy to a specific host (passed to node path)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEPLOY_SH="$SCRIPT_DIR/deploy.sh"

if [ ! -f "$DEPLOY_SH" ]; then
    echo "❌ deploy.sh not found at $DEPLOY_SH" >&2
    exit 1
fi

# Parse a --host override; default target is production1.
TARGET="production1"
ARGS=()
for a in "$@"; do
    case "$a" in
        --host) shift; TARGET="${1:-production1}";;
        *) ARGS+=("$a");;
    esac
done

echo "=== deploy-to-production1.sh -> canonical deploy to $TARGET ==="
exec "$DEPLOY_SH" --deploy-to-node "$TARGET" "${ARGS[@]}"
