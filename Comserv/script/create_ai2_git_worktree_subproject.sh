#!/bin/bash
# Create the "AI2 Editor — Git Worktree Isolation & Review" sub-project under the
# AI Chat Integration project (parent_id=114), mirroring the established pattern in
# create_ai_dev_security_subproject.sh.
#
# Purpose: track, in the in-app project system, the work to give AI code creation its
# own isolated git worktree (create_worktree) plus the Review & Merge flow that
# commits there and merges to main only after the test gate is green. This keeps the
# isolation effort visible in the daily programming workflow / project dashboard.
#
# COMPLIANCE: the /api/project/create endpoint is DEV-ONLY (rejected by production
# instances with api_dev_only). Run this against a WORKTREE / dev instance — NOT the
# production container. Default target is the zenflow worktree on port 4001.
#
# Usage:
#   bash script/create_ai2_git_worktree_subproject.sh            # -> http://localhost:4001
#   BASE=http://localhost:3001 bash script/create_ai2_git_worktree_subproject.sh
set -uo pipefail

BASE="${BASE:-http://localhost:4001}"
PARENT_ID=114   # AI Chat Integration (per create_ai_dev_security_subproject.sh)

echo "=== CREATE AI2 GIT-WORKTREE SUB-PROJECT ==="
echo "Target: $BASE"
echo "Parent: $PARENT_ID (AI Chat Integration)"
echo ""

curl -sS -X POST "$BASE/api/project/create" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "AI2 Editor — Git Worktree Isolation & Review",
    "description": "Give AI code creation its own isolated git worktree so edits/tests never touch main until reviewed. Scope: (1) create_worktree endpoint + zenflow branch per task; (2) AI2 editor Review & Merge panel (list worktrees, diff vs main, run test gate, merge-to-main, push GitHub); (3) Hermes dashboard embed in the editor; (4) track progress via this project. Builds on existing Admin/Git worktree_list/review_diff/merge_to_main/push_main.",
    "project_code": "AI2-GITW",
    "status": "In-Process",
    "start_date": "2026-08-03",
    "end_date": "2026-09-30",
    "estimated_man_hours": 40,
    "project_size": 3,
    "developer_name": "Shanta",
    "client_name": "internal",
    "parent_id": 114,
    "comments": "Zenflow branch: ai2-git-worktree. No standalone worktree-creation plan doc exists yet — backend create_worktree capability is the first build item. Editor UI lives in root/ai2/editor/editing_widget_popup.tt (panels: review, hermes)."
  }'

echo ""
echo ""
if [ "${BASE##*:}" = "3001" ]; then
  echo "NOTE: port 3001 is the PRODUCTION instance and will reject this with api_dev_only."
  echo "Run against a dev/worktree instance (e.g. BASE=http://localhost:4001)."
fi
