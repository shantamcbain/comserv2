# OPENING PROMPT TEMPLATE (Reusable for All Agents)

**Version**: 1.0  
**Purpose**: Establish bilateral audit trail from Prompt 1. Enable immediate /updateprompt Phase 1 logging with USER PROMPT + PLANNED SCOPE.  
**Status**: Reference template - use for all agent sessions to ensure consistency  
**Created**: 2026-01-06

---

## TEMPLATE STRUCTURE

```xml
<role>
[AGENT_ROLE_NAME]: [AGENT_FULL_TITLE]

═══════════════════════════════════════════════════════════════════

BILATERAL AUDIT SETUP (MANDATORY - Prompt 1)
─────────────────────────────────────────────

This opening prompt triggers THREE critical Phase 1 executions:

1. VALIDATION: Execute validation_step0.pl (compliance gate)
2. BILATERAL: Execute /updateprompt --phase before:
   - Log USER PROMPT: "[VERBATIM TEXT FROM THIS OPENING]"
   - Log PLANNED SCOPE: [Explicit scope items below]
3. CONTEXT: Read all required reference files (audit, config, standards)

After Phase 1 logging completes, work proceeds in phases.

═══════════════════════════════════════════════════════════════════

WORKFLOW PHASES (MANDATORY ORDER)

Phase 0: VALIDATION (Prompt 1 - BEFORE ANYTHING ELSE)
  ├─ Execute: validation_step0.pl
  ├─ Purpose: Verify previous chat compliance before starting
  └─ ⚠️ CRITICAL: Phase 0 must complete successfully before Phase 1

Phase 1: BILATERAL SETUP (Prompt 1 - AGENT EXECUTES IMMEDIATELY)
  ├─ **AGENT ACTION**: Execute this EXACT command FIRST in Prompt 1:
  │  perl .zencoder/scripts/updateprompt.pl \
  │    --action "[Brief 1-line summary]" \
  │    --description "USER PROMPT: '[EXACT TEXT FROM OPENING]'. Planned scope: [1-N items]" \
  │    --phase "before" \
  │    --files "[file list]" \
  │    --tools "[tool list]" \
  │    --success 0 \
  │    --notes "Phase 1: Bilateral logging"
  ├─ Verification: Check prompts_log.yaml for entry (non-negotiable)
  ├─ USER PROMPT: "[EXACT OPENING TEXT - not paraphrased]"
  ├─ PLANNED SCOPE: [Items 1-N below]
  └─ Next: Read all reference files (rule #5)

Phase 2: WORK (Prompts 2-N)
  ├─ Agent: Do actual work (edits, analysis, cleanup, etc)
  └─ Agent: Execute /updateprompt --phase after with diffs

Phase 3: DECISION (After each work cycle)
  ├─ Agent: Call ask_questions() for user guidance
  └─ Agent: Execute /updateprompt --phase after with user response

═══════════════════════════════════════════════════════════════════

AGENT ROLE: [AGENT_NAME]
─────────────────────────

**Directive**: [One-sentence description of what agent does]

**Scope**: [Clear definition of what is IN SCOPE]

**Out of Scope**: [Clear definition of what is OUT OF SCOPE]

---

## TASK SPECIFICATION

**Primary Objective**: [Main goal for this session]

**Audit Source**: [Document/config to reference for decisions]
  - Location: [File path or URL]
  - Purpose: [Why this is authoritative]

**Success Criteria**: [What "done" looks like]
  - Criterion 1: [Measurable outcome]
  - Criterion 2: [Measurable outcome]
  - (etc)

---

## EXECUTION PLAN (Sequential Prompts)

**Total Prompts Estimated**: [N]

**Prompt 1** (THIS OPENING):
  - Action: Setup bilateral audit trail
  - Task: Execute validation_step0.pl, /updateprompt Phase 1, read reference files
  - Decision: Ready to proceed?

**Prompt 2**:
  - Action: [Specific action/task]
  - Task: [What will be done]
  - Decision: [Next direction after completion]

**Prompt 3** (if needed):
  - Action: [Specific action/task]
  - Task: [What will be done]
  - Decision: [Next direction]

(Continue for Prompts 4-N as needed)

**Final Prompt**:
  - Action: Verification and completion
  - Task: Confirm success criteria met, log completion
  - Decision: /chathandoff for session closure

---

## MANDATORY RULES (Non-Negotiable)

✅ **REQUIRED**:
- Execute validation_step0.pl before starting work (Phase 0)
- Execute /updateprompt Phase 1 with USER PROMPT logged verbatim (Phase 1)
- Record bilateral audit: user prompt → planned scope → work done → user response
- Use ask_questions() function (never text questions)
- Use EditFile for all code/config changes
- Read files back to verify changes
- Execute /updateprompt Phase 2-3 per protocol

❌ **FORBIDDEN**:
- Skip validation_step0.pl
- Use bash file operations (sed, cat >, echo >>)
- Claim success without verification
- Ask text questions instead of ask_questions()
- Continue work after user response without /updateprompt logging
- Skip any /updateprompt phase

---

## FILE REFERENCES (Read These First)

Before proceeding past Prompt 1, read in order:
1. `.zencoder/coding-standards.yaml` (Rules 1, 2, 5)
2. `.zencoder/rules/PRE-FLIGHT_VALIDATION_CHECKLIST.md`
3. Audit source files (per task specification above)
4. This template (for understanding workflow)

---

## NOTES FOR AGENTS

- **Prompt 1 is SPECIAL**: It establishes bilateral audit from opening. Don't skip phases.
- **Chat Continuity**: Each agent must read current_session.md to understand previous work
- **Compliance First**: validation_step0.pl MUST PASS before any work begins
- **Bilateral is Critical**: USER PROMPT must be logged in Phase 1 (not retroactively)

---

**Template Version**: 1.0  
**Last Updated**: 2026-01-06  
**Used By**: All agents in Zencoder  
**Reference**: Creates proper bilateral audit trail from Prompt 1
