---
description: "Cleanup Agent role specification—code quality, configuration centralization, IDE safety"
alwaysApply: false
---

# Cleanup Agent Role Specification

**Version**: 2.1  
**Updated**: December 14, 2025

---

## Role Objective

Remove inconsistencies, outdated workarounds, and ensure all tools reference a **central coding-standards.yaml**. Focus on:
- Consolidating scattered AI rules into a single authoritative source
- Preventing IDE crashes from conversation loops and token bloat
- Establishing clear tool assignments based on strengths

**⚠️ CRITICAL BOUNDARY**: Zencoder manages ONLY `/.zencoder/rules/` and related Zencoder configuration files.

**Primary Source**: Always parse `/Comserv/root/comserv-ai-guidelines-consolidated.yaml` (Version 2.1+) for all analysis.

---

## Mandatory Workflow Requirements

**BEFORE STARTING WORK**: Read these files in order:
1. `/.zencoder/rules/ask_questions_enforcement.md` - How to ask for user input
2. `/.zencoder/rules/updateprompt-workflow.md` - How to end each prompt properly

**AT THE END OF EVERY PROMPT**: Execute this statement (without exception):
```
[/updateprompt executed] → [PATH A/B/C]
```

**PATHS**:
- **PATH A**: Used `ask_questions()` function; awaiting user response
- **PATH B**: Work complete; no user input needed; prompt done
- **PATH C**: Work in progress; continuing to next task

See `updateprompt-workflow.md` for full details and examples.

---

## Workflow Integration

Execute incrementally per prompt:
- **File**: `/.zencoder/rules/cleanup-agent-workflow.md`
- **Key Sections**: Lines 16-48 (Loop Prevention & Per-Prompt Cycle), Lines 120-150 (Handoff Triggers)

**High-Level Flow**:
1. Analyze YAML
2. Create plan
3. Execute incrementally: Prepare → Edit (one) → User Response

**Best Practices**:
- ✅ Request user input when needed (via `ask_questions()` function)
- ✅ Execute `/updateprompt` statement at end of every prompt
- ✅ Tie priorities to session tracking
- ❌ NEVER batch changes; defer to Workflow for loop prevention

---

## Step 1: Parse Consolidated YAML (PRIMARY SOURCE)

**⚠️ CRITICAL**: Read ONLY from `/Comserv/root/comserv-ai-guidelines-consolidated.yaml`.

**Optional Context File** (CleanupAgent only):
- **Location**: `/Comserv/root/Documentation/session_history/AI_ASSISTANTS_IDE_INTEGRATION_AUDIT.md`
- **Use**: For background context on prior cleanup work and identified inconsistencies
- **Note**: This file is for CleanupAgent reference only; not consulted by other agents

**Extract and Analyze**:
1. **zencoder_configuration** (lines 38-116): Config directories, monitored/excluded paths, external configs.
2. **file_consolidation_plan** (lines 868-904): Tools status, guidelines locations, conflicts, IDE issues.
3. **deprecated_files_status_and_locations** (lines 904-953): Deprecated files with actions.
4. **critical_safety_rules** (lines 121-192): Crash prevention, server control, compaction rules.

---

## Step 2: Review Previous Session Work (OPTIONAL)

**Check**: `/Comserv/root/Documentation/session_history/current_session.md` (create if missing via Workflow).

- If exists: Note resolved vs. pending priorities; reference prior chats (e.g., 15-20 for consolidation).
- If not: Skip and proceed—file auto-creates on first use.
- Tie to priorities below; use for conflict detection.

---

## Step 3: Scan Files/Tools

For each item in YAML or session history:
- Use File Search/Full Text Search (NO CLI).
- Identify: Outdated hacks, duplicates, conflicts, scattered guidelines.
- Categories: Verbose old-model workarounds (remove), repetitions (consolidate), tool overlaps (reassign).

---

## Step 4: Suggest Cleanup Actions

For each issue within Zencoder's scope (ONLY `/.zencoder/rules/` and `/.zencoder/docs/`):
1. **Removals**: Eliminate hacks, delete obsolete sections, archive deprecated files.
2. **Rearrangements**: Migrate to coding-standards.yaml; modularize within `/.zencoder/rules/` only.
3. **Adaptations**: Add cross-tool rules (e.g., "Read coding-standards.yaml first"), document assignments.
4. **Conflict Prevention**: Verify post-change consistency, update links.

**NOTE**: For issues in external tool directories, NOTE the issue but DO NOT modify—those tools manage their own configurations. Reference the consolidated YAML as authoritative source.

---

## Step 5: Create Change Plan

Output before execution (concise Markdown):