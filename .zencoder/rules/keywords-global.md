---
description: "Global keyword system and routing for all Zencoder agents"
alwaysApply: true
---

# Zencoder Global Keywords - REQUIRED FOR ALL AGENTS
**Purpose**: Central registry of global keywords used by ALL Zencoder agents (Cleanup, MainAgent, Debug, etc.)

**Last Updated**: Dec 12 2025  
**Version**: 2.0 (Added /updateprompt as GATING KEYWORD; restructured ask_questions enforcement)

---

## 🔴 GATING KEYWORD REMOVED - SEE WORKFLOW

**NOTE**: `/updateprompt` was previously listed as a keyword but is now **integrated into the agent workflow** as an automated pre-flight gate (see `cleanup-agent-role.md` PRE-FLIGHT GATE section). 

All agents execute /updateprompt automatically at prompt start via workflow automation, not as a manual keyword command. This change integrates gate enforcement into the execution layer rather than the keyword layer.

---

## Quick Reference Table (GLOBAL KEYWORDS)

| Keyword | Format | Status | Cost | Purpose |
|---------|--------|--------|------|---------|
| `/updateprompt` | **WORKFLOW GATE** (see cleanup-agent-role.md) | ✅ Automated | Zero | Pre-flight gate: logs to prompts_log.yaml BEFORE any agent output |
| `/chathandoff` | `/chathandoff [note: X] [prompt: Y]` | ✅ Active | Low | Chat tracking within session |
| `/sessionhandoff` | `/sessionhandoff` | ✅ Active | Low | Session archival & reset |
| `/ask_questions` | `ask_questions()` function call | ✅ Active | Low | **ONLY way to ask for user input** - replaces text questions |
| `/validatett` | `/validatett [file] [doctype]` | ✅ Active | Low | Template Toolkit validation (ALL agents) |

---

## KEYWORD DEFINITIONS

### 1. `/chathandoff` - Chat Tracking (Within Current Session)

**Status**: ✅ Active | **Cost**: Low (file operations only) | **Format**: 
- `/chathandoff`
- `/chathandoff note: [text]`
- `/chathandoff prompt: [text]`
- `/chathandoff note: [text] prompt: [text]`

**Purpose**: Record current chat's entire work in session history file without leaving the session. Captures programming attempted, what worked/failed, resources used, and diagnostic findings.

**Scope**: 
- Updates ONLY `current_session.md`
- Adds ONE new chat entry with complete chat details (18+ lines minimum)
- Resets `.prompt_counter` to 0

**When to Auto-Execute** (AI Agent Responsibility):
1. At end of each chat when significant work completed (code changes, debugging, file modifications)
2. When `current_session.md` file approaches 400 lines
3. When transitioning to significantly different task within same session
4. **COMPACTION PREVENTION**: When response length approaching limit - execute `/chathandoff` INSTEAD of compacting (compaction causes PyCharm crashes and history loss)

**Execution** (IMMEDIATE - NO QUESTIONS):
- File operation only - NO BROWSER REQUIRED
- Add new chat entry to `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/current_session.md`
- Complete current chat details in reverse order (newest chat at top)

**Mandatory Chat Entry Fields** (ALL 7 REQUIRED):
1. **Chat Focus** - Brief description of what this chat focused on
2. **Chat Objective** - Specific goal or task this chat aimed to accomplish
3. **What Happened** - Actions taken during chat (2-4 lines minimum)
4. **Key Achievements** - Concrete accomplishments (1-3 items)
5. **Files Created/Modified** - ALL files listed with status markers (✅/❌/⚠️)
6. **Current Implementation Status** - Progress tracking across chats (3-4 items minimum with ✅/⚠️/❌)
7. **Resource Usage Summary** - Prompt count, tool calls, API quota

**Minimum Entry Length**: 18+ lines per chat entry

**Parameter Processing**:
- `note: [content]` - Incorporate into "What Happened" section
- `prompt: [content]` - Reword into clear continuation prompt for next chat
- **CRITICAL**: Presence of parameters does NOT change execution - ALWAYS execute immediately

**Counter Reset**: After recording chat entry, execute `update_prompt_counter.pl` to reset `.prompt_counter` to 0

**Do NOT Use**: Do NOT use `/chathandoff` when using `/sessionhandoff` in same prompt (use only `/sessionhandoff` - it archives entire session)

---

### 2. `/sessionhandoff` - Session Archival (End of Session)

**Status**: ✅ Active | **Cost**: Low (file operations only) | **Format**: `/sessionhandoff`

**Purpose**: Archive completed session when `current_session.md` exceeds 400 lines OR major task completed. Prepare for next session/working day.

**🔴 MANDATORY ENFORCEMENT**: `/sessionhandoff` MUST use `current_session_template.md` as the format source for resetting `current_session.md`. All agents must enforce this template usage without exception. See Step 3 below for template application rules.

**When to Use**:
- When `current_session.md` approaches 400 lines
- When major task completed (NOT time-based, NOT daily)
- Multiple sessions per day are normal (timestamp prevents data loss)

**Scope**:
- Creates timestamped archive file (prevents data loss on multiple sessions/day)
- Resets `current_session.md`
- Resets `.prompt_counter` to 0

**Execution Steps** (perform in order without analysis between steps):

1. **Capture Timestamp**: Execute `date '+%Y-%m-%d_%H-%M-%S'` command to get current timestamp

2. **Archive Current Session**: Copy `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/current_session.md` to `[TIMESTAMP]_session_archive.md` in same directory
   - Use CURRENT timestamp and date (e.g., `2025-12-07_14-59-04_session_archive.md`)
   - **CRITICAL**: Full timestamp prevents data loss on multiple sessions/day

3. **Reset current_session.md Using Template**: Use WriteFile to completely rewrite `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/current_session.md` using `current_session_template.md` as the format base:

   **MANDATORY TEMPLATE SOURCE**: 
   - Read: `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/current_session_template.md`
   - Use EXACT structure from template lines 1-132 (Session Focus through New Session Instructions)
   - Replace ALL placeholder fields: `[NEW SESSION FOCUS]`, `[AI_ASSISTANT_NAME]`, `[START_DATE]`, `[CURRENT_DATE]`, `[TIMESTAMP]`, `[CHAT_NUMBER]`, `[PREVIOUS_SESSION_STATUS]`, `[PRIMARY_SESSION_OBJECTIVE]`
   - **ENFORCE**: All placeholders must be replaced with actual values (no placeholders in final file)

   **Sections MUST Include** (in this order):
   1. Header with Session Focus, AI Assistant, Session Start, Current Chat Start, System Date, Current Chat Number
   2. ⚠️ CRITICAL HANDOFF TRIGGERS section (from template lines 12-26)
   3. Session Progress Tracking section (from template lines 29-49)
   4. New Session Instructions section (from template lines 52-60)
   5. "Detailed Chat History (Latest First)" heading (from template line 63)
   6. Previous Session Archive table showing all archived sessions with links
   7. Usage Instructions section

   **Previous Session Archive Section** (MOST IMPORTANT - NEW SESSIONS):
   - Create TABLE with columns: Archive File | Session Dates | Major Work | Key Accomplishments
   - **ADD NEW ENTRY AT TOP** with:
     - Link to archived file: `[TIMESTAMP_session_archive.md](./TIMESTAMP_session_archive.md)`
     - Chat numbers: "Chat N" or "Chats N-M"
     - One-line summary of work from previous session
     - Bullet points of key accomplishments (2-3 items max)
   - **PRESERVE ALL EXISTING ENTRIES**: Never delete previous archive entries
   - This allows developers/AI to see historical context by opening current_session.md

4. **Reset Counter**: Execute `perl archive_session_resources.pl` to reset `.prompt_counter` to 0

**Do NOT Use**: 
- Do NOT use with `/chathandoff` in same prompt (session archive makes chat handoff redundant)
- Do NOT use mid-session if file is <400 lines and task not complete
- ❌ Do NOT reset current_session.md without using `current_session_template.md` as format source
- ❌ Do NOT skip template placeholder replacement (all placeholders MUST be replaced with actual values)
- ❌ Do NOT omit any required sections from template

**Enforcement Rules** (Non-Negotiable):
- ✅ ALWAYS read `current_session_template.md` BEFORE resetting current_session.md
- ✅ ALWAYS use template structure as the format base
- ✅ ALWAYS replace ALL placeholders with actual values
- ✅ ALWAYS include ALL 7 required sections (Header, CRITICAL HANDOFF TRIGGERS, Session Progress Tracking, New Session Instructions, Detailed Chat History, Previous Session Archive, Usage Instructions)
- ✅ ALWAYS preserve existing archive entries (never delete)
- ❌ VIOLATION: If current_session.md reset without template usage, agent must immediately re-execute /sessionhandoff correctly and log violation to prompts_log.yaml

**Note**: Use WriteFile (not EditFile) for step 3 - complete file restructure, not incremental edit. Read template first, then write new file using template as guide.

**Resource Note**: Session Handoff is extremely resource-intensive (significant file processing). Developers should chat handoff before executing this function to prevent session exhaustion.

---

### 🚨 3. MANDATORY EXECUTION PATHS AFTER WORKFLOW /updateprompt GATE (CRITICAL - PREVENTS LOCKUPS)

**Status**: ✅ BLOCKING ENFORCEMENT | **Cost**: ZERO | **Format**: Required pattern after /updateprompt executes in workflow

**PURPOSE**: After the /updateprompt workflow gate completes, agent MUST follow ONE of three mandatory paths. Ambiguity causes prompt lockups. (See `cleanup-agent-role.md` PRE-FLIGHT GATE section for gate automation details.)

**The Three Mandatory Paths** (AGENT MUST FOLLOW EXACTLY ONE):

#### **PATH A: Agent asks user a question**
```
1. Execute /updateprompt (log the work)
2. Call ask_questions() function (with options array)
3. WAIT for user response
4. User responds in next prompt
5. Next prompt executes /updateprompt again + continues work
```
✅ **Result**: Prompt waits explicitly for user via ask_questions() function

#### **PATH B: Agent completes work without questions**
```
1. Execute /updateprompt (log the work)
2. Perform the work (edits, reads, etc.)
3. Update /updateprompt entry with success: true
4. State "Prompt complete" OR continue to next task
```
✅ **Result**: Work is logged and prompt explicitly states completion status

#### **PATH C: Agent continues work in same prompt**
```
1. Execute /updateprompt (log current action)
2. Perform work
3. Either loop back to step 1 for next task, OR go to PATH A/B
```
✅ **Result**: Each action is logged; prompt doesn't lock waiting for nothing

**🔴 WHAT CAUSES LOCKUPS** (DO NOT DO):
- ❌ Execute /updateprompt + do work + end prompt WITHOUT asking question or stating complete
- ❌ Execute /updateprompt → ask text question (not using ask_questions() function)
- ❌ Leave prompt in ambiguous state: "Did agent finish or is waiting for input?"
- ❌ Use "Ready to apply?" or similar text questions (these lock IDE waiting for response)

**Agent Enforcement Rules** (MANDATORY - NO EXCEPTIONS):
1. ✅ ALWAYS follow one of the three paths above
2. ✅ ALWAYS state "Prompt complete" if no questions asked + work done
3. ✅ ALWAYS use ask_questions() if user input needed
4. ✅ ALWAYS update /updateprompt success/problems fields after work
5. ❌ NEVER end prompt in ambiguous state
6. ❌ NEVER ask text questions (causes IDE lock)
7. ❌ NEVER skip /updateprompt

**Verification** (for IDE stability):
- If agent executes /updateprompt: Must see one of three paths follow
- If prompt ends without clear path: IDE locks (user must reset)
- If agent asks text question: IDE locks (user must manually provide response)

---

### 4. `/ask_questions()` - ONLY Method for Getting User Input (NOT Text Questions)

**Status**: ✅ Active | **Cost**: Low (blocking user interaction) | **Format**: `ask_questions()` function call

**CRITICAL RULE**: This is the ONLY way agents ask for user input. NO TEXT QUESTIONS.

**Absolute Prohibition**:
- ❌ NEVER ask questions as text: "Should I proceed?" (in normal output)
- ❌ NEVER ask: "Do you want me to..." (in messages)
- ❌ NEVER ask: "Which option..." (expecting user to type answer)
- ✅ ALWAYS use: `ask_questions()` function call (returns structured user response)

**When to Use ask_questions()**:
- User input is needed BEFORE agent can proceed
- Multiple valid approaches exist (ask user to choose)
- Ambiguous requirements (ask for clarification)
- Trade-off decisions (ask user preference)
- Missing critical information

**Execution Sequence When Asking Questions**:
1. ✅ **FIRST**: Execute `/updateprompt` (log that a decision is needed)
2. ✅ **SECOND**: Call `ask_questions()` function with:
   - question: [specific question]
   - options: [array of 2+ options]
3. ✅ **THIRD**: WAIT for user response (do NOT continue)
4. ✅ **FOURTH**: After user responds → Execute `/updateprompt` again (log response + next action)

**Function Syntax**:
```xml
<function_calls>
<invoke name="zencoder-server__ask_questions">
<parameter name="questions">[
  {
    "question": "Your question here?",
    "options": ["Option 1", "Option 2", "Option 3"]
  },
  {
    "question": "Second question (if needed)?",
    "options": ["Option A", "Option B"]
  }
]</parameter>
</invoke>
</function_calls>
```

**Question Format Rules**:
- Each question MUST have: `question` (string) + `options` (array of 2+ choices)
- Multiple questions per batch OK (up to 5)
- Free-text responses: use empty `options` array: `"options": []`
- Make options clear and mutually exclusive

**Agent Responsibility**:
- NEVER ask questions as text
- ONLY use ask_questions() function
- ALWAYS execute `/updateprompt` BEFORE calling ask_questions()
- WAIT for response before continuing
- NO EXCEPTIONS

---

### 5. `/validatett` - Template Toolkit Validation

**Status**: ✅ Active | **Cost**: Low (file operations only) | **Format**:
- `/validatett filename.tt` (single file)
- `/validatett filename.tt doctype` (specify template: application/documentation)
- `/validatett` (batch validate all .tt files in current directory)

**Purpose**: Validates .tt files against appropriate templates for META formatting, PageVersion, and theme compliance. **GLOBAL REQUIREMENT**: All agents creating or editing .tt files MUST run /validatett before committing changes.

**Template Selection**:
- **Documentation folder**: Uses `documentation_tt_template.tt`
- **All other root locations**: Uses `application_tt_template.tt`

**Validates**:
- META section structure (title, description, roles, category, page_version, last_updated, site_specific)
- PageVersion format compliance
- Theme CSS variable usage
- Proper container structure

**Execution**:
- Reports compliance issues and suggests fixes
- Does NOT modify files - validation only
- Creates template files if they don't exist
- Use ViewFile to read target .tt file, compare against appropriate template structure
- Report validation results with specific line numbers and recommendations

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.1 | 2025-12-12 | **CRITICAL FIX**: Added new section 4 "MANDATORY EXECUTION PATHS AFTER /updateprompt" defining three required patterns (PATH A: ask_questions, PATH B: complete+done, PATH C: continue). Prevents prompt lockups by eliminating ambiguous states. Renumbered /ask_questions() to section 5, /validatett to section 6. |
| 2.0 | 2025-12-12 | Restructured /updateprompt as BLOCKING GATE (executes first); added ask_questions() enforcement (ONLY way to ask for user input, replaces text questions); clarified execution sequences with non-negotiable timing rules |
| 1.0 | 2025-12-11 | Extracted global keywords from keywords.md into modular structure; updated /updateprompt for dual-system (current_session.md + prompts_log.yaml) |

