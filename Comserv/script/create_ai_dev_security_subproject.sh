#!/bin/bash
# Create the "AI in Application Development — Security, Code Quality & Checks" sub-project
# under the AI Chat Integration project (parent_id=114), matching the pattern in
# create_ai_chat_subproject.sh.
#
# The /api/project/create endpoint is DEV-ONLY (rejected by production instances), so this
# must be run against a WORKTREE / dev instance, NOT the production container.
# Default target is the zenflow worktree on port 4001 (see create_ai_chat_subproject.sh).
#
# Usage:
#   bash script/create_ai_dev_security_subproject.sh            # -> http://localhost:4001
#   BASE=http://localhost:3001 bash script/create_ai_dev_security_subproject.sh
set -uo pipefail

BASE="${BASE:-http://localhost:4001}"
PARENT_ID=114   # AI Chat Integration (per create_ai_chat_subproject.sh)

echo "=== CREATE AI DEV-SECURITY SUB-PROJECT ==="
echo "Target: $BASE"
echo "Parent: $PARENT_ID (AI Chat Integration)"
echo ""

curl -sS -X POST "$BASE/api/project/create" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "AI in Application Development — Security, Code Quality & Checks",
    "description": "Define how AI (agents, coding assistants, evaluator+editor pattern) is used to build and maintain Comserv2 safely: the gates (perl -c, gitleaks, test_gate, security_scan), consistency rules (.ai-policy.md), human-in-the-loop, workspace/dev-DB isolation, and the check loop. Companion plan: dev_isolation_and_backups_plan.tt",
    "project_code": "AIDEV-SEC",
    "status": "In-Process",
    "start_date": "2026-08-03",
    "end_date": "2026-09-30",
    "estimated_man_hours": 80,
    "project_size": 5,
    "developer_name": "Shanta",
    "client_name": "internal",
    "parent_id": 114,
    "comments": "Zenflow branch: ai-dev-security. Plan docs: root/Documentation/system/ai_dev_security_quality_plan.tt and root/Documentation/system/dev_isolation_and_backups_plan.tt"
  }'

echo ""
echo ""
echo "If the endpoint returned api_dev_only, run this against a DEV/worktree instance (e.g. port 4001),"
echo "not the production container. To promote the plan docs to indexed documentation, the doc indexer"
echo "will pick up root/Documentation/system/*.tt automatically on next scan."
