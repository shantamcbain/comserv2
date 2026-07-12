#!/bin/bash
# post-commit hook — auto-refresh documentation after git changes
# Installed by: ln -sf ../../Documentation/script/post-commit-hook.sh .git/hooks/post-commit

HOOK_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$HOOK_DIR"

# Only run when files under Comserv/lib/Comserv/Controller/ or Comserv/lib/Comserv/Model/ changed
CHANGED_CONTROLLERS=$(git diff-tree --no-commit-id -r -M HEAD -- "Comserv/lib/Comserv/Controller/*.pm" "Comserv/lib/Comserv/Controller/**/*.pm" 2>/dev/null | wc -l)
CHANGED_MODELS=$(git diff-tree --no-commit-id -r -M HEAD -- "Comserv/lib/Comserv/Model/*.pm" "Comserv/lib/Comserv/Model/**/*.pm" 2>/dev/null | wc -l)
CHANGED_SCHEMA=$(git diff-tree --no-commit-id -r -M HEAD -- "Comserv/lib/Comserv/Model/Schema/**/Result/*.pm" 2>/dev/null | wc -l)

TOTAL=$((CHANGED_CONTROLLERS + CHANGED_MODELS + CHANGED_SCHEMA))

if [ "$TOTAL" -gt 0 ]; then
    echo "→ Detected $TOTAL code changes — running doc sync..."
    bash Documentation/script/sync-docs.sh 2>&1 | sed 's/^/  /'
    
    # Stage any auto-updated doc files (no new commit — they ride along)
    git add CLAUDE.md Documentation/SUMMARY.md Documentation/*/SUMMARY.md 2>/dev/null || true
fi

exit 0
