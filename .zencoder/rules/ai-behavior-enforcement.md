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
- **Start Each Response:** Begin every response with current prompt count
- **Track Internally:** Keep running count throughout conversation
- **Warn at Prompt 4:** Alert user that next prompt will trigger handoff
- **Stop at Prompt 5:** Refuse to continue, provide handoff documentation

## MANDATORY APPROVAL WORKFLOW

### Before ANY Code Changes
1. **STOP:** Do not modify any files without explicit user approval
2. **PRESENT:** Show exactly what will be changed using the standard format
3. **WAIT:** Wait for explicit approval ("yes", "approved", "apply changes")
4. **CONFIRM:** Acknowledge approval before proceeding
5. **EXECUTE:** Apply changes only after confirmation

### Standard Change Presentation
```
🔄 PROPOSED CHANGE TO: [filename]
📝 CHANGE TYPE: [Addition/Modification/Deletion]
📋 DESCRIPTION: [what this accomplishes]

❌ CURRENT CODE:
[existing code or "N/A"]

✅ NEW CODE:
[proposed code or "DELETED"]

💡 REASON: [why needed]

⚠️  APPROVAL REQUIRED: Please confirm with "approved" or "yes"
🔄 REVERT: Changes can be undone if needed
```

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