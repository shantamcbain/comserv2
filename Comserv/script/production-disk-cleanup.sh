#!/usr/bin/env bash
# production-disk-cleanup.sh — Safe disk cleanup for Comserv production hosts
# Run on 192.168.1.126 (or via admin SSH cleanup endpoint).
# Does NOT remove named volumes or the running comserv-web-prod image.

set -euo pipefail

SESSION_DIR="${COMSERV_SESSION_DIR:-/home/ubuntu/comserv-sessions}"
LOG_DIR="${COMSERV_LOG_DIR:-/home/ubuntu/comserv-logs}"
SESSION_MAX_AGE_DAYS="${SESSION_MAX_AGE_DAYS:-1}"
LOG_ARCHIVE_KEEP="${LOG_ARCHIVE_KEEP:-10}"

echo "=== Comserv production disk cleanup $(date) ==="
echo "Before: $(df -h / | awk 'NR==2 {print $3 " used of " $2 " (" $5 ")"}')"
echo ""

if [ -d "$SESSION_DIR" ]; then
    before=$(du -sh "$SESSION_DIR" 2>/dev/null | cut -f1)
    echo "1. Pruning session files older than ${SESSION_MAX_AGE_DAYS} day(s) in $SESSION_DIR (was $before)..."
    find "$SESSION_DIR" -type f -mtime +"$SESSION_MAX_AGE_DAYS" ! -name 'comserv_sessions.mmap' -delete 2>/dev/null || true
    after=$(du -sh "$SESSION_DIR" 2>/dev/null | cut -f1)
    remaining=$(find "$SESSION_DIR" -type f 2>/dev/null | wc -l)
    echo "   Sessions: $after ($remaining files)"
fi

if [ -d "$LOG_DIR/archive" ]; then
    echo "2. Trimming log archive (keep newest $LOG_ARCHIVE_KEEP)..."
    find "$LOG_DIR/archive" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | cut -d' ' -f2- | head -n -"$LOG_ARCHIVE_KEEP" \
        | xargs -r rm -f 2>/dev/null || true
fi

if command -v docker >/dev/null 2>&1; then
    echo "3. Docker image prune (dangling only)..."
    docker image prune -f 2>/dev/null | grep -v '^$' || true
    echo "4. Removing unused legacy images (if present)..."
    for img in comserv-catalyst:latest comserv2-web-prod:latest perl:5.36 perl:5.40; do
        docker rmi "$img" 2>/dev/null && echo "   removed $img" || true
    done
    for n in 1 2 3 4 5; do
        docker rmi "shantamcsbain/comserv-web-prod:backup-$n" 2>/dev/null && echo "   removed backup-$n" || true
    done
    echo "5. Docker usage:"
    docker system df 2>/dev/null || true
fi

echo ""
echo "After: $(df -h / | awk 'NR==2 {print $3 " used of " $2 " (" $5 ")"}')"
echo "=== Done ==="