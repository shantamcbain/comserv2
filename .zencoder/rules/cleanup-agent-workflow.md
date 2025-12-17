---
description: "Cleanup Agent workflow—incremental updates with session tracking"
alwaysApply: false
---

# Cleanup Agent Workflow

**Version**: 1.2  
**Updated**: December 07, 2025  

**Changes in 1.2**: Centralized loop prevention; tied to Role's priorities and YAML; clarified no-edit handling; added session entry example.

**Purpose**: Execute Role's objectives incrementally, tracking via /updateprompt to prevent IDE crashes. References Role for analysis/priorities.

**Hierarchy**: Session (multi-chat) > Chat (one task) > Prompt (one edit).

**Key Principle**: One EditFile per prompt → /updateprompt → ask_questions() → User Response.

---

## 🚨 CRITICAL: Loop Prevention Rules

⚠️ **AUTHORITATIVE SOURCE**: See `repo.md` lines 77-157 for complete wrapping-up loop prevention rules

**Quick Reference** (see repo.md for full details):
- Wrapping-up loop: Questions without /updateprompt entry → IDE locks → History lost
- Solution: Type `/updateprompt` → Use Write tool to append session entry → Then ask_questions()
- Three valid patterns: Work→Next, Work→Question, Work→Complete (repo.md details each)

**IDE Stability Rules (Absolute)**:
- No bash/sed/awk—use EditFile only.
- Concise responses; /chathandoff if approaching limits.
- Monitor prompts (<8) and file size (<400 lines).
- ask_questions() ALWAYS with options array (bulleted choices).

---

## Per-Prompt Cycle (Cleanup Agent Specific)

1. **Prepare**: Read target file; plan one change (tie to Role's Steps 3-5 and priorities).
2. **Apply EditFile**: Precise old/new strings; ONE change only.
   - If no edit needed: Still proceed to step 3 (do NOT skip /updateprompt).
3. **Choose One of Two Paths**:

   **Path A - If asking user a question**:
   - Do the work
   - Execute `/updateprompt` (Write tool to add session entry) ← REQUIRED FIRST
   - Call `ask_questions()` function (see repo.md for syntax and rules) ← REQUIRED FORMAT
   - Continue in next prompt when user responds
   
   **Path B - If NOT asking user a question**:
   - Do the work
   - Execute `/updateprompt` at the END of this prompt (Write tool to add session entry)
   - Either continue with next task OR declare work complete (your choice based on priorities)

4. **🚨 MANDATORY QUESTION ENFORCEMENT** (repo.md lines 128-131):
   - ✅ **CORRECT ORDER**: Work → `/updateprompt` → `ask_questions()` function
   - ❌ **NEVER**: Ask questions WITHOUT `/updateprompt` first
   - ❌ **NEVER**: Use plain text questions (e.g., "Should I proceed?")
   - ✅ **ALWAYS**: Use `zencoder-server__ask_questions()` function with `options` array

5. **Global Rules**: See `/.zencoder/rules/repo.md` for rules about question syntax, function usage, and order. Those apply to ALL Zencoder agents, not just Cleanup Agent.

---

## Handoff Triggers

- **Continue Cycle**: More edits in task; prompts <8; file <400 lines.
- **/chathandoff**: Chat complete; size approaching limits; task transition.
- **/sessionhandoff**: File >400 lines; multi-chat end; major priority done.

Reference `keywords.md` for executions.

---

## Session History Entry Format

Grows via /updateprompt; example for a chat:
