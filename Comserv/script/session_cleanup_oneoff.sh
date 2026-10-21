#!/bin/bash
# One-off cleanup of EXPIRED Comserv file-session fallback files.
# Default is a DRY RUN (counts only). Pass --delete to actually remove.
# Only files untouched for longer than session expiry + 1h are removed
# (every session write refreshes mtime), so active sessions are kept.
#
# Usage (inside the container, or against the volume path on the host):
#   script/session_cleanup_oneoff.sh [--delete] [DIR]
#   docker exec comserv2-web-prod /opt/comserv/script/session_cleanup_oneoff.sh
# Env: SESSION_EXPIRES_S (default 86400)
set -u
MODE=dry
[ "${1:-}" = "--delete" ] && { MODE=delete; shift; }
DIR="${1:-${COMSERV_SESSION_DIR:-/tmp/comserv/session}}"
AGE_MIN=$(( ${SESSION_EXPIRES_S:-86400} / 60 + 60 ))
[ -d "$DIR" ] || { echo "No such dir: $DIR"; exit 1; }
TOTAL=$(find "$DIR" -maxdepth 1 -type f | wc -l)
OLD=$(find "$DIR" -maxdepth 1 -type f -mmin +"$AGE_MIN" | wc -l)
echo "Dir: $DIR  total files: $TOTAL  expired (>${AGE_MIN} min untouched): $OLD"
if [ "$MODE" = delete ]; then
    nice -n 19 ionice -c3 find "$DIR" -maxdepth 1 -type f -mmin +"$AGE_MIN" -delete
    echo "Deleted expired files. Remaining: $(find "$DIR" -maxdepth 1 -type f | wc -l)"
else
    echo "Dry run — nothing deleted. Re-run with --delete to remove the expired files."
fi
