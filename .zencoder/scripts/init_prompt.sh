#!/bin/bash
# init_prompt.sh - MANDATORY first action wrapper
# Usage: Called by AI in first response, enforces Phase 0 → Phase 1 → Phase 3
# Created: 2026-01-23 (AI Limitation Mitigation Strategy)

set -e  # Exit on any error

SCRIPT_DIR="/home/shanta/PycharmProjects/comserv2/.zencoder/scripts"
cd /home/shanta/PycharmProjects/comserv2

echo "═══════════════════════════════════════════"
echo "PHASE 0: Validation"
echo "═══════════════════════════════════════════"
perl "$SCRIPT_DIR/validation_step0.pl" || {
    echo "❌ Phase 0 FAILED - Previous prompt had violations"
    echo "   Fix violations before proceeding"
    exit 1
}
echo "✅ Phase 0 PASSED"
echo ""

echo "═══════════════════════════════════════════"
echo "PHASE 1: Bilateral Audit Logging"
echo "═══════════════════════════════════════════"

# Expect AI to provide these via environment or arguments:
# - FULL_PROMPT (entire user prompt verbatim)
# - AGENT_TYPE
# - PLANNED_ACTION (one-line summary)
# - NEW_CHAT (optional: "1" if new conversation)

if [ -z "$FULL_PROMPT" ]; then
    echo "❌ ERROR: FULL_PROMPT environment variable not set"
    echo "   AI MUST set this to the ENTIRE user prompt verbatim"
    echo ""
    echo "   Example:"
    echo "   export FULL_PROMPT='User typed exact text here'"
    exit 1
fi

NEW_CHAT_FLAG=""
CONV_ID=""

if [ "$NEW_CHAT" = "1" ]; then
    NEW_CHAT_FLAG="--new-chat"
    echo "Starting NEW conversation..."
else
    # Continuing existing conversation - get conversation_id
    if [ -f "$SCRIPT_DIR/../current_conversation_id" ]; then
        CONV_ID=$(cat "$SCRIPT_DIR/../current_conversation_id")
        echo "Continuing conversation $CONV_ID..."
    else
        echo "⚠️  WARNING: No conversation_id file found, starting new conversation"
        NEW_CHAT_FLAG="--new-chat"
    fi
fi

# Build updateprompt.pl command
CMD="perl $SCRIPT_DIR/updateprompt.pl"

if [ -n "$NEW_CHAT_FLAG" ]; then
    CMD="$CMD $NEW_CHAT_FLAG"
elif [ -n "$CONV_ID" ]; then
    CMD="$CMD --conversation-id $CONV_ID"
fi

CMD="$CMD --phase before"
CMD="$CMD --action '${PLANNED_ACTION:-Initializing conversation}'"
CMD="$CMD --description 'USER PROMPT (VERBATIM): ${FULL_PROMPT}'"
CMD="$CMD --agent-type '${AGENT_TYPE:-general}'"
CMD="$CMD --full-prompt '$FULL_PROMPT'"
CMD="$CMD --success 0"

# Execute the command
eval $CMD

echo "✅ Phase 1 LOGGED"
echo ""
echo "═══════════════════════════════════════════"
echo "PHASE 3: AI must now call ask_questions()"
echo "═══════════════════════════════════════════"
echo "Next: AI calls ask_questions() to clarify task"
echo "      DO NOT proceed with work until user responds"
