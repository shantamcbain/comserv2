# Zencoder repo.md Restructuring Plan
**Date**: 2025-12-11  
**Status**: IN PROGRESS  
**Priority**: CRITICAL - Fixes ask_questions() invocation & session tracking

---

## Objectives

1. **Separate AI Assistant-level settings from Application-level settings**
   - AI settings: Tool-agnostic protocols (sessions, handoffs, editing, loops)
   - App settings: Comserv-specific (project structure, coding standards, database)

2. **Implement universal current_session.md tracking**
   - All assistants write to same format
   - Tracks: assistant/agent/model, task, code changes, problems, resources
   - Priority order: Assistant info → Task → Changes → Problems → Resources

3. **Reduce confusion with rules, workflows, keywords**
   - Replace scattered examples with clear structured format
   - Link to workflow files (cleanup-agent-workflow.md, keywords.md, etc.)
   - Show actual /updateprompt and ask_questions() execution patterns

---

## Phase 1: Archive & Plan (This Chat)

### 1.1 Archive Current repo.md
- **Source**: `/home/shanta/PycharmProjects/comserv2/.zencoder/rules/repo.md` (889 lines)
- **Target**: `/home/shanta/PycharmProjects/comserv2/Comserv/root/Documentation/session_history/repo.md.archive.2025-12-11`
- **Status**: PENDING

### 1.2 Create New repo.md Structure
**Section A: AI ASSISTANTS LEVEL SETTINGS**
- Session Tracking Protocol
- File Editing Workflows  
- Handoff/Chathandoff Strategy
- Token Budget Management
- Wrapping-Up Loop Prevention

**Section B: ZENCODER-SPECIFIC CONFIGURATION**
- Zencoder-Only Rules
- ask_questions() Protocol (corrected examples with actual invocation)
- Cleanup Agent Workflow (reference)
- Keywords & Execution (reference)

**Section C: APPLICATION LEVEL SETTINGS**
- Project Structure
- Coding Standards Reference
- Database Schema Management
- Documentation Standards

### 1.3 New Session Tracking Format
Create template showing:
- Priority 1: Assistant + Agent + Model
- Priority 2: Task/Problem
- Priority 3: Code Changes
- Priority 4: Problems Encountered
- Priority 5: Resources Used

---

## Phase 2: Implementation (Next Chat)

- [ ] Execute /updateprompt to record Phase 1
- [ ] Move repo.md to archive
- [ ] Create new repo.md with cleaned structure
- [ ] Test /updateprompt and ask_questions() patterns
- [ ] Update current_session.md format

---

## Phase 3: Validation & Refinement

- [ ] Verify all agents can read new repo.md
- [ ] Test ask_questions() invocation examples
- [ ] Validate session tracking across assistant types
- [ ] Update cleanup-agent-role.md references

---

## Files Affected

| File | Action | Status |
|------|--------|--------|
| `/.zencoder/rules/repo.md` | Archive → Move to session_history | PENDING |
| `/.zencoder/rules/repo.md` | Create NEW with clean structure | PENDING |
| `/Comserv/root/Documentation/session_history/current_session.md` | Template definition | PENDING |
| `/.zencoder/rules/cleanup-agent-role.md` | Update references (future) | PENDING |

---

## Key Decisions Made

1. **Archive Strategy**: Full archive (preserve all old content for reference)
2. **Scope**: Zencoder-focused (Continue/others handled separately in .continue/, .codebuddy/ etc.)
3. **Session Format**: Universal (all assistants use same current_session.md structure)
4. **Priority Order**: Assistant info first → down to resource tracking

---

**Next**: Execute Phase 1 steps with /updateprompt and ask_questions() workflow
