---
description: AI Behavior Enforcement Rules for Zencoder
globs: ["**/*"]
alwaysApply: true
priority: 1
---

# AI Behavior Enforcement Rules

## MANDATORY PROMPT TRACKING
**CURRENT PROMPT:** This is prompt #[X] of 5 maximum allowed prompts.

### Prompt Counter Protocol
- **Maximum Prompts:** 5 prompts per session - STRICTLY ENFORCED
- **Track Internally:** Keep running count throughout conversation
- **Warn at Prompt 4:** Alert user that next prompt will trigger handoff
- **Stop at Prompt 5:** Refuse to continue, provide handoff documentation

## APPROVAL-BASED CODE REVIEW WORKFLOW

### 4-Phase Implementation Protocol
1. **ANALYZE:** Complete analysis phase first (read docs, code, logs)
2. **PLAN:** Present comprehensive plan and get user approval
3. **DIFF:** Show exact changes in diff format for user review/editing
4. **APPLY:** Execute changes only after final user approval

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
Show exact changes using +- diff format:
```diff
--- /path/to/file.ext
+++ /path/to/file.ext
@@ -line,count +line,count @@
-old code line
+new code line
 unchanged line
```

### Phase 3: User Review & Edit Opportunity
```
📝 REVIEW REQUIRED: Please review the diff above
✏️ EDIT OPTION: You can modify these changes before I apply them
✅ APPLY: Say "apply" or "yes" to implement these exact changes
🔄 REVERT: Changes can be undone after application if needed
```

### Phase 4: Application (Only After Final Approval)
- Execute changes exactly as shown in approved diff
- Confirm completion
- Provide revert instructions if needed

## VIOLATION CONSEQUENCES
- **Prompt Limit Exceeded:** Immediate session termination with handoff
- **Unapproved Changes:** Acknowledge violation and request approval retroactively
- **Missing Counter:** Add prompt counter to current response

## HANDOFF TEMPLATE (Use on 5th Prompt)
```
🚨 PROMPT LIMIT REACHED - HANDOFF REQUIRED

📊 SESSION SUMMARY:
- Prompts Used: 5/5
- Files Modified: [list]
- Tasks Completed: [list]
- Tasks Remaining: [list]

🔄 HANDOFF PROMPT FOR NEXT AI:
"Continue working on [project/task]. Read development-guidelines.md and ai-behavior-enforcement.md first. 
Current context: [brief context]
Files being worked on: [list]
Next steps needed: [specific actions]"

📚 REQUIRED READING FOR NEXT AI:
- .zencoder/rules/development-guidelines.md
- .zencoder/rules/ai-behavior-enforcement.md
- [any other relevant docs]

✅ DOCUMENTATION UPDATED: [what was recorded]
```

## EMERGENCY PROTOCOLS
- **User Says "Stop":** Immediately cease all activities
- **User Says "Revert":** Provide instructions for undoing changes
- **User Says "Handoff":** Immediately provide handoff documentation