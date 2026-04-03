  ---
description: AI Development Guidelines and Standards
globs: ["**/*.pm", "**/*.tt", "**/*.pl", "**/*.t"]
alwaysApply: true
---

# AI Development Guidelines - Automated Rules

## Core Interaction Constraints

### 5-Prompt Limitation System - STRICTLY ENFORCED
- **Maximum Prompts:** 5 prompts per chat session - NO EXCEPTIONS
- **Current Prompt Counter:** AI must track and announce prompt count at start of each response
- **Reason 1:** Zencoder cost management - additional prompts incur higher charges
- **Reason 2:** AI confusion prevention - performance degrades with extended conversations
- **Action on 5th Prompt:** Automatically update documentation and prepare handoff
- **Enforcement:** AI must refuse to continue beyond 5 prompts and provide handoff

## SYSTEMATIC DEBUGGING WORKFLOW

### Phase 1: Analysis (Prompt 1-2)
1. **Read AI Guidelines:** Review current zencoder rules and standards
2. **Read Documentation:** Study relevant documentation for affected components
3. **Read Codebase:** Examine all related controllers, models, templates (.tt files)
4. **Compare State:** Note discrepancies between documentation and actual code
5. **Read Application Logs:** Verify errors and trace execution path through application
6. **Document Discrepancies:** List all differences found between docs and code

### Phase 2: Planning (Prompt 2-3)
1. **Create Comprehensive Plan:** Include both bug fix and documentation updates
2. **Prioritize Tasks:** 
   - Fix critical documentation discrepancies
   - Implement bug fix
   - Update documentation to reflect new state
3. **Define Success Criteria:** Clear metrics for completion

### Phase 3: Implementation (Prompt 3-4)
1. **Execute Plan:** Implement changes in logical order
2. **Fix Documentation First:** Align docs with current code state
3. **Implement Bug Fix:** Apply necessary code changes
4. **Update Documentation:** Reflect new code functionality
5. **Test Changes:** Verify fix works as expected

### Phase 4: Review & Commit (Prompt 4-5)
1. **Present All Changes:** Show complete diff of all modifications
2. **Document Fix:** Record what was changed and why
3. **Update Plan Status:** Show completed vs remaining tasks
4. **Commit Changes:** Prepare for version control
5. **Handoff Preparation:** If tasks remain, prepare next session context

### 4th Prompt Protocol
When reaching the 4th prompt, the AI must:
1. **Update Documentation:** Record what was attempted and results achieved
2. **Generate Handoff Prompt:** Create a prompt for the next chat session
3. **Reference Documentation:** Remind next AI to read this file and related docs
4. **File Context:** Make sure next prompt knows what files we are working on
5. **Improve Guidelines:** Update workflow to get more work done with fewer prompts
6. **Return Handoff:** Provide handoff prompt in copyable text format

### Task Completion Protocol
Never assume code is done until user tests it in the browser.
When user says "task is completed":
1. **Stop Current Work:** Do not continue with additional tasks
2. **Update Documentation:** Record what was completed in session
3. **Generate Commit Message:** Create appropriate git commit message
4. **Prepare Handoff:** If there are remaining tasks, create handoff prompt

## Application Development Standards

### Documentation Standards - Workstation Configuration
- **File Format:** ONLY `.tt` files (Template Toolkit) - NO `.md` files for app docs
- **PageVersion Standard:** `[% PageVersion = 'path/file.tt,v version YYYY/MM/DD author Exp author' %]`
- **Theme Compliance:** NO page-specific CSS - use theme system only
- **Content Improvement:** Always improve existing files rather than creating new ones

### Database Configuration Priority
- **ZeroTier Address:** 172.30.161.222 (PRIMARY - always available)
- **Local Network:** 192.168.1.198 (SECONDARY - home/office only)
- **Mobile Workstations:** Use ZeroTier addresses for production_server entries

### Error Checking Protocol
- **Always Check:** `logs/application.log` for errors during development
- **Log Locations:** 
  - `/home/shanta/PycharmProjects/comserv2/Comserv/logs/application.log`
  - `/home/shanta/PycharmProjects/comserv2/logs/application.log`

### Logging Protocol
**Standard:** Use `logging_with_details` method for all application logging
**Example Format:**
```perl
$self->logging->log_with_details($c, __FILE__, __LINE__,
    'method_name',
    "Descriptive message with variables: $variable_value");
```

## Development Workflow

### Pre-Development Checklist
1. Read existing documentation in `Comserv/root/Documentation/`
2. Check application logs for any existing issues
3. Verify current system state and dependencies
4. Review relevant navigation system files if working on UI

### During Development
1. Follow application coding standards (see existing code examples)
2. Use proper error handling with try/catch blocks
3. Implement logging using application standards
4. Test changes incrementally
5. Document changes as they are made

### Post-Development
1. Update relevant documentation files (improve existing, don't create new)
2. Add new dependencies to cpanfile if needed
3. Test functionality thoroughly
4. Update guidelines with lessons learned

## Key File Locations

### Navigation System Files
- **Controller:** `/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Controller/Navigation.pm`
- **Main Template:** `/home/shanta/PycharmProjects/comserv2/Comserv/root/Navigation/navigation.tt`
- **Models:** `/home/shanta/PycharmProjects/comserv2/Comserv/lib/Comserv/Model/Schema/Ency/Result/`

### Documentation
- **Main Docs:** `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/`
- **Guidelines:** `/home/shanta/PycharmProjects/comserv2/AI_DEVELOPMENT_GUIDELINES.TT`

### Configuration Files
- **Main Config:** `/home/shanta/PycharmProjects/comserv2/Comserv/comserv.conf`
- **Database Config:** `/home/shanta/PycharmProjects/comserv2/Comserv/config/database.yml`

### Common Issues & Solutions
- **Issue:** [Add common problems you encounter]
- **Solution:** [Add proven solutions]

### Rule Effectiveness Notes
- **Last Updated:** [Date]
- **What's Working Well:** [Successful patterns]
- **What Needs Improvement:** [Areas for refinement]
- **Recent Discoveries:** [New insights to incorporate]

## File and Directory Management Rules - CRITICAL

### ALWAYS Use Existing Files/Directories First
- **NEVER CREATE NEW:** Always search for and use existing files before creating new ones
- **DIRECTORY CONSISTENCY:** Use existing directory structures - don't create new directories
- **FILE INVENTORY:** Check what files already exist in target directories before creating
- **CONSOLIDATION PRIORITY:** Improve/update existing files rather than creating duplicates
- **NAMING CONFLICTS:** If similar files exist (e.g., `navigation` vs `Navigation`), consolidate into the established standard

### Examples of Problems to Avoid
- **Duplicate Directories:** We have both `navigation` and `Navigation` directories - use the established one
- **Duplicate Files:** Creating `new_file.tt` when `existing_file.tt` should be updated
- **Scattered Content:** Creating multiple files for same topic instead of consolidating

### Before Creating Any File/Directory
1. **Search First:** Use file search tools to find existing similar files
2. **Check Directory Structure:** Look at existing directory organization
3. **Ask User:** If unsure, ask user which existing file should be updated
4. **Document Consolidation:** Note when consolidating duplicate files

## Communication Efficiency Rules
- **Avoid External Commands:** Don't ask user to run commands outside the chat
- **Stay Within Scope:** Focus only on requested functions
- **Minimize Prompts:** Each communication counts toward the 4-prompt limit
- **Direct Action:** Use available tools directly instead of requesting external actions

## Code Change Approval Protocol - MANDATORY
### User Must Approve ALL Code Changes
- **NEVER APPLY CHANGES WITHOUT APPROVAL:** All code modifications must be explicitly approved by user
- **Show Changes First:** Always present proposed changes for review before applying
- **Clear Change Indicators:** Use clear formatting to highlight what will be changed
- **Wait for Confirmation:** Do not proceed with any file modifications until user confirms
- **Revert Option:** Always inform user that changes can be reverted if needed
- **Change Summary:** Provide clear summary of what each change accomplishes

### Change Presentation Format
When proposing code changes, use this format:
```
PROPOSED CHANGE TO: /path/to/file.ext
CHANGE TYPE: [Addition/Modification/Deletion]
DESCRIPTION: Brief description of what this change does

OLD CODE:
[existing code or "N/A" for additions]

NEW CODE:
[proposed new code or "DELETED" for removals]

REASON: Why this change is needed
```

### Approval Required Before Action
- **Explicit Approval:** User must say "approved", "yes", "apply changes", or similar
- **No Assumptions:** Do not assume silence means approval
- **Batch Approval:** For multiple changes, get approval for each file or ask for batch approval
- **Rollback Plan:** Always mention how changes can be undone