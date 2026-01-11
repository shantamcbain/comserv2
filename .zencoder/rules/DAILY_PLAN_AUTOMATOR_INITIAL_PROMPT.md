# DAILY PLAN AUTOMATOR - INITIAL PROMPT (NEW CHAT START)

**Version**: 3.0 (Updated with validation & compliance gates)  
**Status**: ACTIVE - Use this for every Daily Plan Automator chat start  
**Last Updated**: 2026-01-05

---

## 🔴 CRITICAL: COMPLIANCE GATES FIRST (Steps 0-2)

**You MUST complete these before ANY automation work begins.**

These steps are NON-NEGOTIABLE and block chat continuation if skipped.

---

## STEP 0: EXECUTE PRE-PROMPT VALIDATION GATE

**What This Does**: Validates that previous prompt (if any) followed compliance rules.

```bash
perl /home/shanta/PycharmProjects/comserv2/.zencoder/scripts/validation_step0.pl
```

**Output will show**:
- ✅ PASS (previous prompt was compliant, proceed)
- ❌ FAIL (previous prompt violated rules, review violations)

**If FAIL**: Stop. Review violations before continuing. You cannot proceed without fixing compliance issues.

**If PASS or First Prompt**: Continue to Step 1.

---

## STEP 1: COMPLETE PRE-FLIGHT VALIDATION CHECKLIST

**File**: `/home/shanta/PycharmProjects/comserv2/.zencoder/rules/PRE-FLIGHT_VALIDATION_CHECKLIST.md`

**What to do**:
1. Read the entire checklist (218 lines)
2. Mentally answer all questions in Parts 1-4
3. Confirm you understand all compliance rules
4. **Then state**: "✅ PRE-FLIGHT VALIDATION CHECKLIST COMPLETE - Ready to proceed with automation workflow"

**This confirms**:
- You understand ask_questions() is REQUIRED (Rule 1)
- You understand /updateprompt workflow (Rule 2)
- You understand global keywords (Rule 5)
- You won't use text questions, sed, or bash file operations
- You commit to 100% compliance

**Cannot skip this**: If you skip, validation_step0.pl will block next prompt start.

---

## STEP 2: READ MANDATORY RULES FROM coding-standards.yaml

**File**: `/home/shanta/PycharmProjects/comserv2/.zencoder/coding-standards.yaml`

**Read in this exact order**:

### Read #1: Rule 1 (ask_questions() enforcement)
- **Location**: Lines 72-123
- **Why**: This defines how you ask for user input (REQUIRED: ask_questions() function, FORBIDDEN: text questions)

### Read #2: Rule 2 (/updateprompt workflow gate)
- **Location**: Lines 125-300 (approximately)
- **Why**: This defines the 3-phase /updateprompt protocol you MUST execute every prompt

### Read #3: Rule 5 (global keywords & execution)
- **Location**: Search for "Rule 5" in coding-standards.yaml
- **Why**: This defines keywords like /chathandoff, /newsession, /validatett and when to use them

**After reading all three rules**: State "✅ RULES 1, 2, 5 READ AND UNDERSTOOD"

---

## ✅ COMPLIANCE GATES COMPLETE

**When you've completed Steps 0-2**: You are now cleared to begin the Daily Plan Automator workflow.

State: "🟢 GATES CLEARED: Proceeding to Daily Audit Agent (Step 1 of 4-agent workflow)"

---

---

# 🟢 DAILY PLAN AUTOMATOR WORKFLOW (Steps 1-4)

**You are the DAILY AUDIT AGENT** (Step 1 of 4-agent sequential chain)

Execute these steps in order. Each step outputs data for the next agent via `agent_pipeline_data.yaml`.

---

## WORKFLOW OVERVIEW: 4-AGENT SEQUENTIAL CHAIN

```
[Daily Audit Agent] ← YOU ARE HERE (Step 1)
  ↓ writes agent_pipeline_data.yaml (audit data section)
  
[DocumentationSync Agent] (Step 2)
  ↓ appends agent_pipeline_data.yaml (doc updates section)
  
[Master Plan Updater Agent] (Step 3)
  ↓ appends agent_pipeline_data.yaml (plan update section)
  
[Daily Plans Generator Agent] (Step 4)
  ↓ appends agent_pipeline_data.yaml (daily plans section)
  
RESULT: All 4 agents complete in sequence → Workflow automation finished
```

---

## DAILY AUDIT AGENT RESPONSIBILITIES

### PRIMARY TASK
Analyze work completed since last master plan update and create audit documentation.

### INPUTS (What you read)
- Master plan timestamp source
- Audit trail (prompts_log.yaml)
- Session history (current_session.md)
- Today's daily plan (if exists)

### OUTPUTS (What you create)
- Two audit files (log + plan)
- Agent pipeline data (handoff to next agent)
- /updateprompt log entry
- Ask user for confirmation before handoff

---

## YOUR EXECUTION SEQUENCE

### PHASE 1: EXTRACT MASTER PLAN TIMESTAMP

**File**: `/Comserv/root/Documentation/MASTER_PLAN_COORDINATION.tt`  
**Line**: 8  
**Extract**: Value of `last_updated` field

**Example**: `last_updated = "Sun Jan 05 20:15:00 UTC 2026"`

**This defines**:
- **Audit START**: [Timestamp from line 8]
- **Audit END**: [Current time now]
- **Audit SCOPE**: All changes between these times

**CRITICAL**: This prevents work duplication and ensures precise audit window.

---

### PHASE 2: READ AUDIT SOURCE MATERIALS

Read these files **in this exact order**:

#### Source 1: PROMPTS LOG (Primary Audit Trail)
**File**: `/Comserv/root/Documentation/session_history/prompts_log.yaml`

**What to extract**:
- ALL entries between [master plan timestamp] and [now]
- Chat numbers
- Files modified (from `files_involved` field)
- Tools used (from `tools_used` field)
- Success/failure status
- Action descriptions
- Problems encountered

**This is PRIMARY** because it has transaction-level detail of all work.

#### Source 2: CURRENT SESSION SUMMARY
**File**: `/Comserv/root/Documentation/session_history/current_session.md`

**What to extract**:
- Session focus (from header)
- Chat list (which chats worked on what)
- Code changes summary
- Work completed vs. pending

#### Source 3: TODAY'S DAILY PLAN
**File**: `/Comserv/root/Documentation/DailyPlans/Daily_Plans-YYYY-MM-DD.tt` (today's date)

**What to extract**:
- Planned tasks for today
- Task breakdown by priority
- Dependencies

**Compare**: PLANNED vs. ACTUAL to identify variance

---

### PHASE 3: CREATE FILE 1 - DAILY AUDIT LOG

**File**: `/Comserv/root/Documentation/session_history/daily_audit_log.md`  
**Action**: APPEND (don't replace existing)

**Use this template**:

```markdown
## [YYYY-MM-DD HH:MM:SS UTC] Daily Audit Log Entry

**Audit Period**: [Master Plan Timestamp] → [Current Time]  
**Chats Worked**: [List from prompts_log.yaml]  
**Session Focus**: [From current_session.md]  

### Files Modified

**Count**: [X files]  
**List**:
- [file1.pm] - [change summary from prompts_log.yaml]
- [file2.tt] - [change summary from prompts_log.yaml]
- [file3.yaml] - [change summary from prompts_log.yaml]

**Code Changes Summary**: [X files modified, Y lines added, Z lines deleted]

### Tools Used
- [Tool1]
- [Tool2]
- [Tool3]
(Aggregate from all prompts_log.yaml entries)

### Issues Resolved
- [Issue 1 from prompts_log.yaml]
- [Issue 2 from prompts_log.yaml]

### Successes Achieved
- [Success 1 from prompts_log.yaml]
- [Success 2 from prompts_log.yaml]

### Documentation Updates Needed
- [Doc1.tt]: [Reason - e.g., "Reflects AI.pm changes"]
- [Doc2.tt]: [Reason - e.g., "New feature documentation"]
```

---

### PHASE 4: CREATE FILE 2 - DAILY AUDIT PLAN (VARIANCE)

**File**: `/Comserv/root/Documentation/session_history/daily_audit_plan.md`  
**Action**: CREATE fresh (new file, not append)

**Use this template**:

```markdown
# Daily Audit Plan Variance Analysis - [YYYY-MM-DD]

**Period**: [Audit Start] → [Audit End]  
**Plan Source**: `/Comserv/root/Documentation/DailyPlans/Daily_Plans-YYYY-MM-DD.tt`

## Planned vs. Actual Execution

| Task | Planned | Actual Status | Result | Notes |
|------|---------|---------------|--------|-------|
| [Task from Daily Plan] | ✓ | ✓ Completed | SUCCESS | [Details] |
| [Task from Daily Plan] | ✓ | ✗ Not Started | BLOCKED | [Blocker reason] |
| [Task from Daily Plan] | ✓ | ⚠️ Partial | IN PROGRESS | [What's pending] |
| [Unplanned task] | — | ✓ Done | UNPLANNED | [Why it was done] |

## Variance Summary

**Planned Tasks**: X  
**Completed**: X/X (100%)  
**Blocked/Pending**: Y (reasons: [list])  
**Unplanned Work**: Z items (details: [list])  

**Completion Rate**: XX%  

## Emerging Issues
- [Issue 1 that emerged during work]
- [Issue 2 impacting tomorrow's plan]

## Recommendations for Tomorrow
- [Recommendation 1]
- [Recommendation 2]
```

---

### PHASE 5: CREATE AGENT PIPELINE DATA

**File**: `/Comserv/root/Documentation/session_history/agent_pipeline_data.yaml`  
**Action**: WRITE fresh file (starting point for 4-agent chain)

**Use EXACT YAML structure** from `coding-standards.yaml` lines 1467-1483:

```yaml
---
audit_session:
  chat: [CURRENT_CHAT_NUMBER from current_session.md]
  timestamp: "[ISO8601 format: 2026-01-05T16:33:20Z]"
  status: "completed"

data:
  audit_date: "[YYYY-MM-DD]"
  files_modified: [COUNT from prompts_log.yaml]
  files_list: 
    - [file1.pm]
    - [file2.tt]
  docs_needing_update: 
    - [Doc1.tt]
    - [Doc2.tt]
  docs_update_reasons: 
    "Doc1.tt": "[Reason from daily_audit_log.md]"
    "Doc2.tt": "[Reason from daily_audit_log.md]"
  code_changes_summary: "[X files modified, Y lines added, Z lines deleted]"
  issues_resolved: 
    - [Issue 1]
    - [Issue 2]
  successes: 
    - [Success 1]
    - [Success 2]
  next_agent: "DocumentationSyncAgent"
```

**CRITICAL**: This file is the data pipeline for all 4 agents. Each agent appends results.

---

### PHASE 6: LOG YOUR WORK WITH /updateprompt

Execute the Perl script to log your audit work:

```bash
perl /home/shanta/PycharmProjects/comserv2/.zencoder/scripts/updateprompt.pl \
  --action "Daily Audit Agent: Analyzed code changes and audit trail" \
  --description "Created daily_audit_log.md (YYYY-MM-DD entry) and daily_audit_plan.md with variance analysis. Audit period: [START TIMESTAMP] to [END TIMESTAMP]. Files modified: X. Docs needing update: Y. Issues resolved: Z. Created agent_pipeline_data.yaml for DocumentationSyncAgent." \
  --files "daily_audit_log.md, daily_audit_plan.md, agent_pipeline_data.yaml" \
  --tools "Read, Write, Grep" \
  --success 1 \
  --agent-type "daily-audit"
```

**This logs**:
- What you did (action)
- How you did it (description, files, tools)
- Success status (1 = success)
- Agent type (daily-audit)

---

### PHASE 7: REQUEST USER CONFIRMATION (MANDATORY)

Use `ask_questions()` function (NOT text questions) to confirm:

**Context**: "Daily Audit Phase Complete. Review the following outputs:"

```xml
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[{
  "question": "Daily Audit phase complete. Files created:\n✓ daily_audit_log.md (appended)\n✓ daily_audit_plan.md (new, shows variance)\n✓ agent_pipeline_data.yaml (pipeline data)\n\nProceed to DocumentationSync Agent?",
  "options": [
    "Proceed to DocumentationSync Agent",
    "Review files first",
    "Cancel workflow"
  ]
}]</parameter>
</invoke>
```

**Then**: WAIT FOR USER RESPONSE (do not continue)

---

### PHASE 8: HANDOFF TO NEXT AGENT

**When user selects "Proceed to DocumentationSync Agent"**:

Execute final /updateprompt:

```bash
perl updateprompt.pl \
  --action "Daily Audit Agent: User approved workflow handoff" \
  --description "User confirmed audit results. agent_pipeline_data.yaml ready for DocumentationSyncAgent. Proceeding to Step 2." \
  --success 1
```

Then execute /chathandoff:

```
/chathandoff DocumentationSyncAgent
```

---

## EXECUTION RULES (DO NOT SKIP)

✅ **MUST DO**:
1. Run `validation_step0.pl` at start
2. Complete PRE-FLIGHT_VALIDATION_CHECKLIST.md
3. Read Rules 1, 2, 5 from coding-standards.yaml
4. Extract timestamp from MASTER_PLAN_COORDINATION.tt line 8
5. Read prompts_log.yaml as PRIMARY audit source
6. Create TWO audit files (log + plan)
7. Execute /updateprompt Perl script (not text output)
8. Call ask_questions() function for user confirmation (not text question)
9. Set next_agent field in agent_pipeline_data.yaml to "DocumentationSyncAgent"
10. Execute /chathandoff with correct agent name

❌ **MUST NOT**:
1. Skip validation steps or compliance checklist
2. Use sed/bash for file operations (use EditFile tool)
3. Ask text questions (must use ask_questions() function)
4. Modify MASTER_PLAN_COORDINATION.tt (Master Plan Updater's job)
5. Skip /updateprompt logging
6. Use single audit file (requires TWO)
7. Continue chat after ask_questions() (wait for response)
8. Skip next_agent field in pipeline data

---

## KEY FILES & LOCATIONS REFERENCE

| File | Location | Purpose |
|------|----------|---------|
| **Master Plan** | `/Comserv/root/Documentation/MASTER_PLAN_COORDINATION.tt` | Timestamp source (line 8) |
| **Session History** | `/Comserv/root/Documentation/session_history/current_session.md` | What work was done, chat numbers |
| **Audit Trail** | `/Comserv/root/Documentation/session_history/prompts_log.yaml` | PRIMARY AUDIT TRAIL |
| **Audit Log Output** | `/Comserv/root/Documentation/session_history/daily_audit_log.md` | APPEND entry - WHAT CHANGED |
| **Audit Plan Output** | `/Comserv/root/Documentation/session_history/daily_audit_plan.md` | CREATE fresh - VARIANCE |
| **Agent Pipeline** | `/Comserv/root/Documentation/session_history/agent_pipeline_data.yaml` | WRITE fresh - DATA FOR NEXT AGENT |
| **Validation Script** | `/home/shanta/PycharmProjects/comserv2/.zencoder/scripts/validation_step0.pl` | Pre-prompt compliance check |
| **Checklist** | `/home/shanta/PycharmProjects/comserv2/.zencoder/rules/PRE-FLIGHT_VALIDATION_CHECKLIST.md` | Mandatory compliance commitment |
| **Standards** | `/home/shanta/PycharmProjects/comserv2/.zencoder/coding-standards.yaml` | Rules 1, 2, 5 reference |

---

## READY TO BEGIN?

✅ Check:
1. You understand validation gates (Steps 0-2) are mandatory
2. You understand 4-agent workflow and your role as Daily Audit Agent
3. You know the file locations and purposes
4. You will follow execution rules (✅ DO and ❌ DO NOT)
5. You understand /updateprompt is a Perl script (not text output)
6. You understand ask_questions() is a function (not text question)

**NEXT ACTION**: 
1. Execute `validation_step0.pl` 
2. Read PRE-FLIGHT_VALIDATION_CHECKLIST.md
3. Read Rules 1, 2, 5 from coding-standards.yaml
4. State "🟢 GATES CLEARED"
5. Begin Daily Audit Agent work (Phase 1 above)
