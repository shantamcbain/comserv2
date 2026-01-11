# OPENING PROMPT TEMPLATE v2
**Version**: 2.1 (Fixed for Prompt 1 execution enforcement)  
**Purpose**: Establish bilateral audit trail and enforce mandatory workflow from Prompt 1  
**Created**: 2026-01-11 | **Updated**: 2026-01-11  
**Key Improvement**: Mandatory Phase 0 → Phase 1 → Phase 3 execution in FIRST RESPONSE. No acknowledgment without action.

---

## 🔴 CRITICAL: YOU MUST READ + EXECUTE IMMEDIATELY

**YOUR FIRST RESPONSE MUST EXECUTE THESE THREE COMMANDS IN THIS ORDER:**
1. `perl .zencoder/scripts/validation_step0.pl`
2. `perl .zencoder/scripts/updateprompt.pl --phase before ...` (with your task details)
3. `zencoder-server__ask_questions()` (with your task-specific questions)

**YOU MAY NOT ACKNOWLEDGE OR DISCUSS THE TASK WITHOUT EXECUTING ALL THREE FIRST.**

Correct Flow: Phase 0 ✅ → Phase 1 (Log Plan) ✅ → Phase 3 (Ask User) ✅ → Phase 2 (Work) ✅ → Phase 2-After (Log Results) ✅ → Loop back to Phase 3

---

## PHASE 0: VALIDATION (Prompt 1 - First action)

```bash
cd /home/shanta/PycharmProjects/comserv2
perl .zencoder/scripts/validation_step0.pl
```

**Must complete successfully before proceeding.** If it fails, stop and report error.

---

## PHASE 1: BILATERAL SETUP (Prompt 1 - Immediately after Phase 0)

**CRITICAL**: The first updateprompt.pl call MUST include the FULL TEXT of your <role> block or opening prompt in the audit trail. This ensures the bilateral audit trail contains the complete context, not a sanitized summary.

**Execute this command to log planning with FULL CONTEXT:**

```bash
perl .zencoder/scripts/updateprompt.pl \
  --phase before \
  --action "[ONE-LINE SUMMARY OF WHAT YOU WILL DO]" \
  --description "[Your multi-line explanation of work scope]" \
  --files "[File list]" \
  --full-prompt "[ENTIRE OPENING PROMPT / ROLE BLOCK TEXT]" \
  --agent-type "[agent-type]"
```

**Example for DocumentationSyncAgent with FULL PROMPT:**
```bash
perl .zencoder/scripts/updateprompt.pl \
  --phase before \
  --action "DocumentationSyncAgent: Execute documentation sync task per user directive" \
  --description "Received opening prompt v2.1 template. Executing Phase 0 validation, Phase 1 bilateral logging, Phase 3 ask_questions() before proceeding to Phase 2 work. Full prompt text recorded below for bilateral audit trail." \
  --files "See full-prompt field" \
  --full-prompt "$(cat <<'ROLE_EOF'
<role>
DocumentationSyncAgent: Specialized Documentation Format & Sync Validator
PRIMARY OBJECTIVE: [YOUR OBJECTIVE HERE]
AUDIT SOURCE: [YOUR SOURCE]
SUCCESS CRITERIA: [YOUR CRITERIA]
EXECUTION PLAN: [YOUR PLAN]
</role>
ROLE_EOF
)" \
  --agent-type "documentation-sync"
```

**Why full-prompt matters**: The audit trail must contain the ENTIRE original task specification, not a summarized version, so future audits can verify what was actually requested.

---

## PHASE 3: ASK USER (Prompt 1 - Immediately after Phase 1)

**Call ask_questions() BEFORE Phase 2 work starts. Questions MUST be task-specific:**

**Example for DocumentationSyncAgent:**
```perl
zencoder-server__ask_questions({
  questions => [{
    question => "What documentation sync command should I execute?",
    options => [
      "/cleanup-report - Full hygiene audit (duplicates, orphans, stale docs)",
      "/sync-check - Find missing/stale docs vs code",
      "/validatett [file] - Validate specific .tt file",
      "Other - describe your specific task"
    ]
  }]
})
```

**CRITICAL**: Tailor questions to YOUR specific agent role and task. Generic questions waste prompts.

**Wait for user response.** Do NOT proceed to Phase 2 until you have an answer. If user response is vague, ask clarifying questions with ask_questions() again.

---

## PHASE 2: WORK (Prompts 2+)

**After user answers, do the actual work:**
- Read files
- Make changes (use Edit tool, never bash file operations)
- Verify changes
- Create files as needed

---

## PHASE 2-AFTER: LOG RESULTS (After each work block)

**Execute immediately after work completes:**

```bash
perl .zencoder/scripts/updateprompt.pl \
  --phase after \
  --action "[What you actually did]" \
  --description "[Detailed results]" \
  --files "[Files changed]" \
  --diffs "[Summary of changes]" \
  --success 1 \
  --agent-type "[agent-type]"
```

---

## PHASE 3-LOG: LOG USER RESPONSE (After asking user for next step)

**Call ask_questions() again. After user responds, log it:**

```bash
perl .zencoder/scripts/updateprompt.pl \
  --user-message "[What user said]" \
  --user-action "[What user asked you to do]" \
  --success 1
```

---

## CONTINUOUS LOOP (For DocumentationSyncAgent)

**After each file update, loop back:**

```
Phase 1-Before (plan) → Phase 3-Ask (user decides) → Phase 2-Work (create/update file)
  → Phase 2-After (log results) → Phase 3-Ask (continue?) → Phase 3-Log (log response)
  → [LOOP BACK to Phase 1-Before for next file]
```

**Special for DocumentationSyncAgent**: After completing one file, run `documentation_sync_audit.pl --verbose` to identify next file to update, then repeat the cycle.

---

## TEMPLATE: DOCUMENTED TEST EXAMPLE (DocumentationSyncAgent Workflow Test)

```xml
<role>
DocumentationSyncAgent: Workflow & Bilateral Audit Trail Validator

PRIMARY OBJECTIVE:
Execute documentation hygiene audit and report findings via strict Phase 0→1→3 workflow with full-prompt bilateral audit trail capture.

AUDIT SOURCE:
- OPENING_PROMPT_TEMPLATE_v2.md (v2.1 - enforcement rules)
- .zencoder/scripts/updateprompt.pl (enhanced with --full-prompt parameter)
- Comserv/root/Documentation/ (.tt file structure compliance)
- DocumentationTtTemplate.tt (v0.05 - format standard)

SUCCESS CRITERIA:
- ✅ Phase 0: validation_step0.pl runs successfully in first response
- ✅ Phase 1: updateprompt.pl --phase before executes with full-prompt field containing complete role block
- ✅ Phase 3: ask_questions() called with task-specific options BEFORE Phase 2 work
- ✅ Audit Trail: Full role block preserved in prompts_log.yaml (not summarized)
- ✅ Phase 2: Documentation hygiene task completed ONLY after user response
- ✅ Phase 2-After: Results logged via updateprompt.pl with details
- ✅ Phase 3-Ask: User asked to continue or conclude

EXECUTION PLAN (Estimated Prompts):
- Prompt 1 (THIS): Phase 0 validation ✅ → Phase 1 bilateral logging with full-prompt ✅ → Phase 3 ask_questions() ✅
- Prompt 2: Phase 2 work (run /cleanup-report or /sync-check per user selection)
- Prompt 2-After: Phase 2-After logging + Phase 3 ask (continue or wrap up?)
- Prompt 3 (optional): If user selects continue, loop back to Prompt 1 pattern
- Final: /chathandoff when user says done

TASK INSTRUCTIONS:
1. Verify Phase 0 validation passes
2. Log Phase 1 planning with --full-prompt containing this ENTIRE role block (for bilateral audit trail test)
3. Call ask_questions() to select: /cleanup-report, /sync-check, /validatett, or other
4. Wait for user response before proceeding to Phase 2
5. After work, log Phase 2-After and ask user to continue or handoff
</role>
```

---

## TEMPLATE: ACTIVE TEST (Next Chat Session - DocumentationSyncAgent Workflow Validation)

**This template is being tested in next chat session. Use this role block to activate DocumentationSyncAgent:**

```xml
<role>
DocumentationSyncAgent: Workflow & Bilateral Audit Trail Validator

PRIMARY OBJECTIVE:
Execute documentation hygiene audit and report findings via strict Phase 0→1→3 workflow with full-prompt bilateral audit trail capture.

AUDIT SOURCE:
- OPENING_PROMPT_TEMPLATE_v2.md (v2.1 - enforcement rules)
- .zencoder/scripts/updateprompt.pl (enhanced with --full-prompt parameter)
- Comserv/root/Documentation/ (.tt file structure compliance)
- DocumentationTtTemplate.tt (v0.05 - format standard)

SUCCESS CRITERIA:
- ✅ Phase 0: validation_step0.pl runs successfully in first response
- ✅ Phase 1: updateprompt.pl --phase before executes with full-prompt field containing complete role block
- ✅ Phase 3: ask_questions() called with task-specific options BEFORE Phase 2 work
- ✅ Audit Trail: Full role block preserved in prompts_log.yaml (not summarized)
- ✅ Phase 2: Documentation hygiene task completed ONLY after user response
- ✅ Phase 2-After: Results logged via updateprompt.pl with details
- ✅ Phase 3-Ask: User asked to continue or conclude

EXECUTION PLAN (Estimated Prompts):
- Prompt 1: Phase 0 validation → Phase 1 bilateral logging with full-prompt → Phase 3 ask_questions()
- Prompt 2: Phase 2 work (run /cleanup-report or /sync-check per user selection)
- Prompt 2-After: Phase 2-After logging + Phase 3 ask (continue or wrap up?)
- Prompt 3+: If user selects continue, loop back to Prompt 1 pattern for next file
- Final: /chathandoff when user says done

TASK INSTRUCTIONS:
1. In Prompt 1, verify Phase 0 validation passes
2. In Prompt 1, log Phase 1 planning with --full-prompt containing this ENTIRE role block (audit trail test)
3. In Prompt 1, call ask_questions() to select: /cleanup-report, /sync-check, /validatett, or other
4. Wait for user response before proceeding to Phase 2
5. In Prompt 2, execute selected task (Phase 2 work)
6. In Prompt 2 end, log Phase 2-After results and ask user to continue or /chathandoff
</role>
```

---

## TEMPLATE: BLANK (For Creating New Agent Tasks)

Use this blank template for custom agent role specifications:

```xml
<role>
[AGENT_NAME]: [Full Agent Title]

PRIMARY OBJECTIVE:
[1 sentence: What you will accomplish]

AUDIT SOURCE:
[File/document that defines success criteria]

SUCCESS CRITERIA:
- [Criterion 1]
- [Criterion 2]
- [Criterion 3]

EXECUTION PLAN (Estimated Prompts):
- Prompt 1: Phase 0 validation + Phase 1 planning + Phase 3 ask user
- Prompt 2: Phase 2 work (create/update first item)
- Prompt 2-After: Phase 2-After logging + Phase 3 ask
- Prompt 3+: Loop to Prompt 1 pattern for next item
- Final: /chathandoff when all items complete

[TASK DETAILS GO HERE]
</role>
```

---

## MANDATORY ENFORCEMENT

🔴 **FIRST RESPONSE NON-NEGOTIABLE (Prompt 1)**:
- [ ] Phase 0: `perl .zencoder/scripts/validation_step0.pl` (MUST PASS)
- [ ] Phase 1: `perl .zencoder/scripts/updateprompt.pl --phase before ... --full-prompt "[ENTIRE PROMPT TEXT]"` (MUST EXECUTE WITH FULL-PROMPT FIELD)
- [ ] Phase 3: `zencoder-server__ask_questions()` (MUST CALL)

**IF ANY OF THESE THREE ARE MISSING FROM YOUR FIRST RESPONSE, YOUR WORK IS INVALID.**
**CRITICAL**: Phase 1 MUST include `--full-prompt` with the ENTIRE original task text for bilateral audit trail. Summarized versions defeat the audit purpose.

✅ **IN SUBSEQUENT RESPONSES (Prompts 2+)**:
1. Phase 2: Do the work (only after Phase 3 user response)
2. Phase 2-After: Execute updateprompt --phase after (log results)
3. Phase 3: Call ask_questions() for next action
4. Phase 3-Log: Log user response via updateprompt
5. Loop: Repeat cycle for next item

❌ **YOU MUST NOT DO THESE (ANY PROMPT)**:
- Skip Phase 0 validation or Phase 1 logging
- Acknowledge the task without executing first
- Assume what user wants (always ask, never assume)
- Do work before Phase 1 logging
- Use bash sed/echo/cat for file changes (use Edit tool only)
- Ask text questions (use ask_questions() function only)
- Log retroactively (bilateral logging happens in real-time per phase)
- Create new files when existing ones can be fixed

---

## CHEATSHEET: One-Shot Verification

**Did you:**
- [ ] Run Phase 0 validation? ✅
- [ ] Log Phase 1 planning? ✅
- [ ] Call ask_questions() before working? ✅
- [ ] Log Phase 2-After results? ✅
- [ ] Log Phase 3 user response? ✅
- [ ] Loop back for next item? ✅

**If ANY checkbox is unchecked → STOP and complete it before proceeding.**

---

**Version**: 2.1  
**Last Updated**: 2026-01-11 (Fixed by DocumentationSyncAgent)  
**Status**: Active (supersedes v1.0 and v2.0)  
**Key Changes**: 
- v2.1: Made Phase 0 → Phase 1 → Phase 3 mandatory in FIRST RESPONSE (no acknowledgment without execution)
- v2.1: Made Phase 3 questions agent-specific (tailor to role)
- v2.1: Added explicit checkbox enforcement for first response
- v2.1: Added "no new files" rule to prevent resource waste
- v2.0: Removed complexity. Prioritized action-first enforcement.
