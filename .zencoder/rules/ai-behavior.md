---
description: "AI behavioral constraints and approval-based workflow"
globs: []
alwaysApply: true
---

# AI Behavior and Workflow Standards

## Core Interaction Constraints

- **Clarification**: Always use `ask_questions` to ask questions when requirements are unclear.
- **Execution**: Never run the application unless explicitly requested by the user.
- **File Management**: Do not create new documents or code files if one already exists for the same purpose.
- **Consolidation**: If there are two or more documents or code files for the same purpose, ask to consolidate them into one.

## APPROVAL-BASED CODE REVIEW WORKFLOW

### 4-Phase Implementation Protocol
1. **ANALYZE**: Complete analysis phase first (read docs, code, logs).
2. **PLAN**: Present comprehensive plan and get user approval.
3. **DIFF**: Show exact changes in diff format for user review/editing.
4. **APPLY**: Execute changes only after final user approval.

### Phase 1: Planning & Approval
Present plan in this format:
```
🔄 PROPOSED PLAN: [brief description]
📋 FILES TO MODIFY: [list of files]
📝 CHANGES OVERVIEW: [what will be accomplished]
💡 REASON: [why this approach]

⚠️ APPROVAL REQUIRED: Please confirm with "yes" or "approved"
```

### Phase 2: Diff Presentation (After Approval)
Show exact changes using +- diff format.

### Phase 3: User Review & Edit Opportunity
```
📝 REVIEW REQUIRED: Please review the diff above
✏️ EDIT OPTION: You can modify these changes before I apply them
✅ APPLY: Say "apply" or "yes" to implement these exact changes
🔄 REVERT: Changes can be undone after application if needed
```

### Phase 4: Application (Only After Final Approval)
- Execute changes exactly as shown in approved diff.
- Confirm completion.
- Provide revert instructions if needed.

## File and Directory Management Rules - CRITICAL

### ALWAYS Use Existing Files/Directories First
- **NEVER CREATE NEW**: Always search for and use existing files before creating new ones.
- **DIRECTORY CONSISTENCY**: Use existing directory structures - don't create new directories.
- **FILE INVENTORY**: Check what files already exist in target directories before creating.
- **CONSOLIDATION PRIORITY**: Improve/update existing files rather than creating duplicates.
- **NAMING CONFLICTS**: If similar files exist (e.g., `navigation` vs `Navigation`), consolidate into the established standard.

## Communication Efficiency Rules
- **Avoid External Commands**: Don't ask user to run commands outside the chat.
- **Stay Within Scope**: Focus only on requested functions.
- **Minimize Unnecessary Back-and-Forth**: Keep communication focused and actionable.
- **Direct Action**: Use available tools directly instead of requesting external actions.

## HANDOFF TEMPLATE (Use when user requests handoff)
```
🚨 HANDOFF REQUESTED

📊 SESSION SUMMARY:
- Files Modified: [list]
- Tasks Completed: [list]
- Tasks Remaining: [list]

🔄 HANDOFF PROMPT FOR NEXT AI:
"Continue working on [project/task]. Read repo.md and ai-behavior.md first. 
Current context: [brief context]
Files being worked on: [list]
Next steps needed: [specific actions]"

📚 REQUIRED READING FOR NEXT AI:
- .zencoder/rules/repo.md
- .zencoder/rules/ai-behavior.md
- [any other relevant docs]

✅ DOCUMENTATION UPDATED: [what was recorded]
```

## EMERGENCY PROTOCOLS
- **User Says "Stop"**: Immediately cease all activities.
- **User Says "Revert"**: Provide instructions for undoing changes.
- **User Says "Handoff"**: Immediately provide handoff documentation.
