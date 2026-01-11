# Daily Plan Automator - CORRECTED WORKFLOW

**Version**: 2.0 (Corrected)  
**Date**: 2026-01-05  
**Previous Version**: 1.0 (INCORRECT - Removed)  
**Status**: ACTIVE - Use this instead of old role specification

---

## CRITICAL CORRECTIONS FROM VERSION 1.0

### ❌ Version 1.0 Was WRONG Because:
1. **Master Plan Location**: Incorrectly specified `master_plan.md` - WRONG
   - **CORRECT**: `/Comserv/root/Documentation/MASTER_PLAN_COORDINATION.tt` (Template Toolkit file)
   
2. **Audit File Count**: Incorrectly specified single `audit_YYYY-MM-DD.md` file
   - **CORRECT**: TWO files needed:
     - `daily_audit_log.md` (appended entries, contains summary + identified doc updates)
     - `daily_audit_plan.md` (new file tracking variance: planned vs. accomplished)
   
3. **DocumentationSync Handoff**: Did not specify how data passed to next agent
   - **CORRECT**: Uses `agent_pipeline_data.yaml` (YAML file structured per coding-standards.yaml)
   
4. **Timestamp Source**: Did not know where to find "last master plan update"
   - **CORRECT**: Extract from `MASTER_PLAN_COORDINATION.tt` `last_updated` field (line 8)
   
5. **Prompts Log**: Did not leverage prompts_log.yaml for audit trail
   - **CORRECT**: prompts_log.yaml has MORE info than current_session.md; this is the real audit trail
   
6. **/updateprompt Usage**: Did not understand timing
   - **CORRECT**: Call /updateprompt on EACH significant exchange:
     - When user gives prompt/command → log user message
     - When agent completes work → log agent action
     - Creates continuous audit trail

---

## CORRECTED WORKFLOW (4-AGENT CHAIN)

```
User gives work command
         ↓
[Step 1] Daily Audit Agent
  → Reads: current_session.md, prompts_log.yaml, MASTER_PLAN_COORDINATION.tt
  → Creates: daily_audit_log.md + daily_audit_plan.md
  → Writes: agent_pipeline_data.yaml (audit data)
  → /updateprompt → /chathandoff
         ↓
[Step 2] DocumentationSync Agent
  → Reads: agent_pipeline_data.yaml (doc list from Step 1)
  → Creates: Updates to doc files (validates template, checks accuracy)
  → Appends: agent_pipeline_data.yaml (updated docs summary)
  → /updateprompt → /chathandoff
         ↓
[Step 3] Master Plan Updater Agent
  → Reads: agent_pipeline_data.yaml (complete audit + doc updates)
  → Creates: Updates MASTER_PLAN_COORDINATION.tt (timestamp, status)
  → Appends: agent_pipeline_data.yaml (master plan update section)
  → /updateprompt → /chathandoff
         ↓
[Step 4] Daily Plans Generator Agent
  → Reads: agent_pipeline_data.yaml (updated priorities from Step 3)
  → Creates: Daily_Plans-YYYY-MM-DD.tt files (today + next 7 days)
  → Appends: agent_pipeline_data.yaml (daily plans generated)
  → /updateprompt → /chathandoff
         ↓
WORKFLOW COMPLETE - All agents executed in sequence
```

---

## STEP 1: DAILY AUDIT AGENT

### Responsibilities

1. **Read Historical Data**
   - `current_session.md` - Latest chat entries (what was done)
   - `prompts_log.yaml` - Complete audit trail (all exchanges logged)
   - `MASTER_PLAN_COORDINATION.tt` - Extract `last_updated` timestamp (line 8)
   - Today's Daily Plan file: `Daily_Plans-YYYY-MM-DD.tt` (planned work)

2. **Determine Audit Period**
   - Start: Extract `last_updated` timestamp from MASTER_PLAN_COORDINATION.tt
   - End: Current time (now)
   - Scope: All changes made during this period

3. **Query prompts_log.yaml**
   - Find all entries between [last_updated] and [now]
   - Group by chat number
   - Extract files modified, tools used, success status

4. **Create Two Audit Files**

   **File 1: daily_audit_log.md** (Appended)
   ```markdown
   ## [YYYY-MM-DD HH:MM:SS UTC] Daily Audit

   **Period**: [Last Master Plan Update] → [Now]
   **Chats Worked**: [List all chat numbers from current_session.md]
   **Session Focus**: [Copy from current_session.md header]

   ### Code Changes Summary
   - **Files Modified**: [Complete list with paths]
     - `lib/Comserv/Controller/AI.pm` - Added message query filtering (lines 234-251)
     - `root/ai/index.tt` - Updated display template (lines 45-67)
   - **Total**: X files, YYY+ lines changed

   ### Issues Encountered
   - **Issue 1**: [Description] - Status: ✅ Resolved / 🔄 Ongoing / ❌ Blocked
   - **Issue 2**: [Description] - Status: [Status]

   ### Successes Achieved
   - ✅ [Achievement 1]
   - ✅ [Achievement 2]

   ### Documentation Updates Needed
   - **To Update**: Documentation/controllers/AI.tt (reflects message filtering changes)
   - **To Update**: Documentation/templates/ai.tt (display template updates)
   - **To Create**: [Any new docs]

   ### Resource Usage
   - **Period**: [Start time] → [End time]
   - **Chats**: [Count]
   - **Prompts**: [Count from prompts_log.yaml]
   - **Files**: [Count]
   - **Lines**: +X/-Y

   ### Next Steps
   - [Copy from current_session.md NEXT STEPS]
   ```

   **File 2: daily_audit_plan.md** (Create/Update)
   ```markdown
   ## [YYYY-MM-DD] Daily Audit: Plan vs. Accomplishment

   **Date**: [YYYY-MM-DD]
   **Session**: [Session name from current_session.md]

   ### Planned Work (from Daily_Plans-YYYY-MM-DD.tt)
   - Task 1: [Description]
   - Task 2: [Description]
   - Task 3: [Description]

   ### Actual Work Completed
   - ✅ Task 1: COMPLETED [Details]
   - ⏳ Task 2: PENDING [Reason]
   - ❌ Task 3: NOT ADDRESSED [Reason]
   - 🆕 Extra Task: COMPLETED [Why was this needed]

   ### Variance Analysis
   | Plan | Status | Accomplishment | Notes |
   |------|--------|-----------------|-------|
   | Task A | ✅ | Completed task A fully | On schedule |
   | Task B | ⏳ | Started but not finished | Blocker: [X] |
   | Task C | 🆕 | Extra work done: [Y] | Needed for [Z] |

   ### Resource Usage
   - Planned: X hours
   - Actual: Y hours
   - Variance: [+/- explanation]

   ### Recommendations
   - [For next daily plan]
   - [For agent tuning]
   ```

5. **Write Agent Pipeline Data**
   
   File: `agent_pipeline_data.yaml`
   ```yaml
   audit_session:
     chat: <current_chat_number>
     timestamp: <ISO8601_datetime>
     status: "completed"
   data:
     audit_date: "YYYY-MM-DD"
     audit_period_start: <ISO8601_from_master_plan_last_updated>
     audit_period_end: <ISO8601_now>
     files_modified: <count>
     files_list: ["file1.pm", "file2.tt", ...]
     docs_needing_update: ["Doc1.tt", "Doc2.tt", ...]
     docs_update_reasons: {"Doc1.tt": "Reflects AI.pm changes", ...}
     code_changes_summary: "X lines added/modified, Y deleted"
     issues_resolved: ["Issue1", ...]
     successes: ["Success1", ...]
     next_agent: "DocumentationSyncAgent"
   ```

6. **Execute /updateprompt**
   ```bash
   perl updateprompt.pl \
     --action "Daily Audit Agent: Analyzed code changes and identified documentation updates" \
     --description "Created daily_audit_log.md and daily_audit_plan.md covering period from [last_update] to now. Identified X files modified, Y documentation updates needed. Audit period: [date range]. See agent_pipeline_data.yaml for complete data flow." \
     --files "daily_audit_log.md, daily_audit_plan.md, agent_pipeline_data.yaml, prompts_log.yaml" \
     --tools "Read, Write, Grep, Bash" \
     --success 1
   ```

7. **Ask for Confirmation**
   ```
   use ask_questions() with options:
   - "Yes - proceed with DocumentationSync"
   - "Yes - but skip some docs"
   - "No - skip documentation updates"
   ```

---

## STEP 2: DOCUMENTATION SYNC AGENT

### Responsibilities

1. **Read Agent Pipeline Data**
   - Open: `agent_pipeline_data.yaml`
   - Extract: `data.docs_needing_update` (file list)
   - Extract: `data.docs_update_reasons` (context for each)
   - Verify: `next_agent: "DocumentationSyncAgent"` (confirms this agent should run)

2. **For Each Documentation File**
   - Read the documentation file
   - Read the corresponding code file (to verify accuracy)
   - Validate Template Toolkit conformance:
     - META block present with correct fields
     - PageVersion line formatted correctly
     - No inline CSS colors (use var(--*))
     - last_updated field matches current date
   - Update content to reflect code changes
   - Increment version in META (e.g., 1.00 → 1.01)
   - Update last_updated timestamp

3. **Validation Errors**
   - If template validation fails: STOP and report violation
   - If code/doc mismatch found: Alert user, suggest correction
   - If doc is outdated: Mark with status = "Needs Review"

4. **Append Agent Pipeline Data**
   ```yaml
   documentation_sync:
     docs_updated: ["Doc1.tt (v1.00→v1.01)", "Doc2.tt (v1.00→v1.01)", ...]
     docs_update_count: <count>
     versions_incremented: {"Doc1.tt": "v1.00→v1.01", ...}
     format_violations_fixed: <count>
     validation_results: "✅ All files valid"
     issues_found: [...]
     successes: [...]
     next_agent: "Master Plan Updater"
   ```

5. **Execute /updateprompt**
   ```bash
   perl updateprompt.pl \
     --action "DocumentationSync Agent: Updated documentation files to match code changes" \
     --description "Updated X documentation files reflecting code changes from Daily Audit Agent. Validated all .tt files for template conformance. Version increments: [list]. All files now synchronized with code." \
     --files "Documentation/controllers/AI.tt, Documentation/templates/ai.tt, agent_pipeline_data.yaml" \
     --tools "Read, Edit, Write, Grep" \
     --success 1
   ```

---

## STEP 3: MASTER PLAN UPDATER AGENT

### Responsibilities

1. **Read Agent Pipeline Data**
   - Open: `agent_pipeline_data.yaml`
   - Read ALL sections: `data` + `documentation_sync`
   - Verify: `next_agent: "Master Plan Updater"` field

2. **Update MASTER_PLAN_COORDINATION.tt**
   - Update `last_updated` field (line 8) to current timestamp
   - Update progress status (line 21) with:
     - Latest audit date
     - Summary of changes
     - Link to audit files
   - Update daily plan reference (lines 43-44)
   - Reorder priorities if needed based on audit findings

3. **Append Agent Pipeline Data**
   ```yaml
   master_plan_update:
     plan_version_old: "X.XX"
     plan_version_new: "X.XX+1"
     timestamp: <ISO8601>
     sections_updated: ["status", "daily_plan_reference", "priority_reranking"]
     top_10_reranked: ["Initiative1", ...]
     timeline_adjustments: {}
     next_agent: "Daily Plans Generator"
   ```

4. **Execute /updateprompt**
   ```bash
   perl updateprompt.pl \
     --action "Master Plan Updater Agent: Updated MASTER_PLAN_COORDINATION.tt with audit results" \
     --description "Updated master plan v0.XX→v0.YY with latest audit data. Updated last_updated timestamp, status field with audit summary, daily plan reference. Priorities remain stable based on audit variance analysis." \
     --files "MASTER_PLAN_COORDINATION.tt, agent_pipeline_data.yaml" \
     --tools "Read, Edit, Write" \
     --success 1
   ```

---

## STEP 4: DAILY PLANS GENERATOR AGENT

### Responsibilities

1. **Read Agent Pipeline Data**
   - Open: `agent_pipeline_data.yaml`
   - Read: `master_plan_update` (priorities, timeline)
   - Extract: Top priorities for next 7 days

2. **Read Updated Master Plan**
   - Open: `MASTER_PLAN_COORDINATION.tt` (just updated)
   - Extract priorities and sequencing

3. **Generate Daily Plans**
   - Create: `Daily_Plans-YYYY-MM-DD.tt` (today)
   - Create: `Daily_Plans-YYYY-MM-DD.tt` (tomorrow through +7 days)
   - Each file contains:
     - Priority tasks for that day
     - Estimated time/effort
     - Dependencies
     - Success criteria
   - Update master plan link to today's daily plan

4. **Append Agent Pipeline Data**
   ```yaml
   daily_plans_generated:
     plans_created: 8  # Today + next 7 days
     date_range: "YYYY-MM-DD to YYYY-MM-DD"
     priorities_followed: ["P1", "P2", "P3"]
     next_agent: null  # End of chain
     status: "complete"
   ```

5. **Execute /updateprompt**
   ```bash
   perl updateprompt.pl \
     --action "Daily Plans Generator Agent: Created daily plans for next 8 days (today through +7)" \
     --description "Generated Daily_Plans files for 2026-01-05 through 2026-01-12. Priorities follow updated master plan. All plans linked from MASTER_PLAN_COORDINATION.tt navigation dashboard." \
     --files "Daily_Plans-2026-01-05.tt, Daily_Plans-2026-01-06.tt, Daily_Plans-2026-01-07.tt, Daily_Plans-2026-01-08.tt, Daily_Plans-2026-01-09.tt, Daily_Plans-2026-01-10.tt, Daily_Plans-2026-01-11.tt, Daily_Plans-2026-01-12.tt, MASTER_PLAN_COORDINATION.tt, agent_pipeline_data.yaml" \
     --tools "Read, Write, Edit" \
     --success 1
   ```

---

## EXECUTION CHECKLIST

### For Daily Audit Agent:
- [ ] Read current_session.md (latest chat entries)
- [ ] Read prompts_log.yaml (complete audit trail)
- [ ] Extract master plan update timestamp from MASTER_PLAN_COORDINATION.tt (line 8)
- [ ] Identify all changes between [timestamp] and [now]
- [ ] Create daily_audit_log.md entry (appended)
- [ ] Create daily_audit_plan.md file (planned vs. actual)
- [ ] Write agent_pipeline_data.yaml (Step 1 data)
- [ ] Execute /updateprompt with action + description
- [ ] Ask user confirmation before proceeding to Step 2

### For DocumentationSync Agent:
- [ ] Read agent_pipeline_data.yaml (verify doc list from Step 1)
- [ ] For each file in docs_needing_update:
  - [ ] Read documentation file
  - [ ] Validate Template Toolkit conformance
  - [ ] Read corresponding code file
  - [ ] Verify accuracy and sync with code
  - [ ] Update documentation content
  - [ ] Increment version
  - [ ] Update last_updated
- [ ] Append agent_pipeline_data.yaml with documentation_sync section
- [ ] Execute /updateprompt with all updated files listed
- [ ] Ask user confirmation before proceeding to Step 3

### For Master Plan Updater Agent:
- [ ] Read agent_pipeline_data.yaml (complete audit + doc updates)
- [ ] Open MASTER_PLAN_COORDINATION.tt
- [ ] Update last_updated field (line 8)
- [ ] Update status/summary (line 21) with audit results
- [ ] Update daily plan reference (lines 43-44)
- [ ] Append agent_pipeline_data.yaml with master_plan_update section
- [ ] Execute /updateprompt
- [ ] Ask user confirmation before proceeding to Step 4

### For Daily Plans Generator Agent:
- [ ] Read updated MASTER_PLAN_COORDINATION.tt
- [ ] Read agent_pipeline_data.yaml (priorities)
- [ ] Generate Daily_Plans-*.tt files (8 files: today + 7 days)
- [ ] Update master plan daily plan link
- [ ] Append agent_pipeline_data.yaml with daily_plans_generated section
- [ ] Execute /updateprompt with all daily plan files listed
- [ ] Mark workflow COMPLETE

---

## KEY INSIGHTS

1. **Timestamp Matters**: Audit period is defined by MASTER_PLAN_COORDINATION.tt's `last_updated` field
   - This keeps audit window current
   - Prevents duplicating work
   - Enables continuous integration

2. **Two Audit Files Serve Different Purposes**:
   - `daily_audit_log.md` - **What changed** (code, docs, issues, successes)
   - `daily_audit_plan.md` - **Did we execute the plan?** (variance tracking for oversight)

3. **Agent Pipeline Data is Single Source of Truth**:
   - Each agent appends its output
   - Next agent reads entire file (all previous outputs)
   - No information is lost between agents
   - /updateprompt logs reference this file

4. **Every Exchange Gets /updateprompt**:
   - User prompt → /updateprompt logs user message
   - Agent work → /updateprompt logs agent action
   - Creates continuous audit trail in prompts_log.yaml

5. **DocumentationSync is Critical**:
   - Validates template conformance
   - Verifies code/doc accuracy
   - Increments versions
   - Without this step, documentation drifts from code

---

## VERSION HISTORY

| Version | Date | Changes |
|---------|------|---------|
| 2.0 | 2026-01-05 | **CORRECTED**: Fixed master plan location (.tt file), clarified two audit files, added agent_pipeline_data.yaml flow, specified timestamp source, corrected /updateprompt usage. Completely rewrote workflow from version 1.0 which was incorrect. |
| 1.0 | 2025-12-XX | Initial (INCORRECT - DO NOT USE) |

