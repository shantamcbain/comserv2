# Current Session Tracking

**Session Focus**: [NEW SESSION FOCUS]. Guideline: Never update this line until we change sessions. Please follow this guideline! do not remove it.
**AI Assistant**: [AI_ASSISTANT_NAME] (Current Chat)
**Session Start**: [START_DATE] → [CURRENT_DATE] (Ongoing Session) Guideline: use date to get current date
**Current Chat Start**: [TIMESTAMP]  
**System Date**: [CURRENT_DATE]
**Current Chat number**: [CHAT_NUMBER] Start with 1 on a new chat incrementally update with each chat handoff.

---

## ⚠️ CRITICAL HANDOFF TRIGGERS

**When to handoff to a new session:**
1. **Chat Length Threshold**: Current chat approaches 18+ prompts (indicates focus degradation incoming)
2. **Repetition Pattern**: Same issue being "fixed" without actual resolution across 2+ chats
3. **Role Drift**: Task shifting away from stated session focus without user direction
4. **Resource Warning**: AI reports token budget constraints (triggers fresh thinking space)
5. **User-Requested Handoff**: User executes `/handoff` keyword (immediate priority)

**Handoff Protocol**:
- Create `YYYY-MM-DD_session_handoff.md` with complete current_session.md copy
- Archive to `YYYY-MM-DD_session_archive.md` with git commit reference
- Reset current_session.md from template
- Fresh start allows AI to approach problems without accumulated session state

---

## Session Progress Tracking

### use date for current dates

**PREVIOUS SESSION ARCHIVED**: [PREVIOUS_SESSION_STATUS]

**CATEGORICAL SUMMARIES AVAILABLE:**
- `[session_focus]_summary.md`: Core session focus and ongoing development goals
- `ai_relationship_summary.md`: AI assistant history organization and protocol compliance work  
- `documentation_summary.md`: Documentation update attempts and file editing issues
- `completed_tasks_summary.md`: Template synchronization, roles verification, and configuration updates

**PRIMARY OBJECTIVE**: [PRIMARY_SESSION_OBJECTIVE]

**NEXT STEPS**: 
1. Check the documentation for the session focus and ongoing development goals 
2. Create a new plan if it is not in the documentation.
3. Review development plan in `development_plan.md`
4. Define by the new session objective
5. Maintain focus on session objective

---

## New Session Instructions

The new AI assistant should:
1. Review the summary files to understand previous work if they are for the session objective. Documentation is the definitive source of truth. 
2. Check `development_plan.md` for implementation roadmap. This file is a general guideline for the Development and may not contain all the details. 
3. Continue with [session focus] as primary session focus
4. Update this file with new session details when starting
5. **MANDATORY**: Add complete chat entries in reverse chronological order (latest first)

---

## Detailed Chat History (Latest First) this is were you put the details of the chat on each /chathanoff.

### **Template Instructions for Chat Entry**

When adding your chat entry, use this exact format (MINIMUM 18 lines per chat - do NOT compress below this):

```
### **Chat N ([DATE TIME] - [CHAT_TITLE] - [STATUS])**

**Chat Focus**: [Brief description of what this chat focused on - 1 line MINIMUM]
**Chat Objective**: [Specific goal or task this chat aimed to accomplish - 1 line MINIMUM]
**AI Assistant**: [AI_ASSISTANT_NAME]  
**Session Status**: [COMPLETED/IN_PROGRESS/NEEDS_CONTINUATION]
- Record information of the entire chat ordered by prompt.
**What Happened** (2-4 lines minimum):
1. **[MAJOR_ACTION_1]**: [Description of what was done]
2. **[MAJOR_ACTION_2]**: [Description of what was done]
3. **[MAJOR_ACTION_3]**: [Description of what was done]

**Key Achievements** (1-3 items):
- **[ACHIEVEMENT_1]**: [Description]
- **[ACHIEVEMENT_2]**: [Description]

**Files Created/Modified** (LIST ALL - do NOT hide):
- ✅ `/full/path/to/file1` - [What was done]
- ✅ `/full/path/to/file2` - [What was done]
- ❌ `/full/path/to/problem_file` - [Issue encountered]
- ⚠️ `/full/path/to/partial` - [Partially complete work]

**Technical Details** (2-4 lines minimum):
- ✅ **[TECHNICAL_ASPECT_1]**: [Implementation details - show what works]
- ❌ **[TECHNICAL_PROBLEM]**: [Problem description - show what DOESN'T work]
- **Reason**: [Why it didn't work or what blocked it]

**Current Implementation Status** (MANDATORY - Required for multi-chat visibility):
- ✅ **[COMPLETED_ITEM]**: [Status description - when was this truly completed]
- ⚠️ **[PARTIAL_ITEM]**: [Status description - what's still needed]
- ❌ **[FAILED_ITEM]**: [Status description - why it failed]
- 🔄 **[IN_PROGRESS]**: [What's being worked on now - explicit continuation marker]

**Is This Issue Related to Previous Chat?**
- If fixing something from earlier chat(s), LIST WHICH ONES: "Chat N, Chat M"
- If same issue repeated: "⚠️ REPETITION DETECTED: Same [issue description] as Chat N"
- If issue resolved: "✅ RESOLVED: [Original issue] was [how it was fixed]"

**Handoff Signals** (Check ALL that apply - explicit handoff triggers):
- [ ] Chat length approaching 18+ prompts (fresh thinking needed)
- [ ] Same issue being "fixed" again without actual resolution
- [ ] Task drifting away from session focus
- [ ] User executed `/handoff` keyword
- [ ] Repetitive pattern detected across multiple chats

**Resources Used**: [List of tools and files accessed]
- File Operations: ViewFile ([N] files), EditFile ([N] edits)
- Search Operations: file_search, fulltext_search
- Browser Operations: [if any]
- Shell Operations: ExecuteShellCommand

**Chat Completion**: [Summary of what was accomplished, what remains, and clear handoff instructions for next session]

---
**CRITICAL NOTES FOR NEXT CHAT:**
- [Any specific findings that must be carried forward]
- [Corrections or clarifications from user feedback]
- [Files that need continued work]
```

---

## Session Template Usage Instructions

**For AI Assistants starting a new session:**

1. **Copy this template**: Run `cp current_session_template.md current_session.md`
2. **Update session information**: Replace all `[PLACEHOLDER]` values with actual information
3. **Set session focus**: Define the primary objective for the entire session
4. **Update dates and timestamps**: Use current system date and time
5. **Add your first chat entry**: Follow the provided template format

**Key Placeholders to Replace:**
- `[NEW SESSION FOCUS]`: The primary objective for the entire session
- `[AI_ASSISTANT_NAME]`: Your AI assistant name (e.g., Zencoder, Copilot, Cascade)
- `[START_DATE]`, `[CURRENT_DATE]`: Actual dates in YYYY-MM-DD format
- `[TIMESTAMP]`: Current timestamp in YYYY-MM-DD HH:MM:SS PDT format
- `[PRIMARY_SESSION_OBJECTIVE]`: Detailed description of session goals

**Session Focus Guidelines:**
- Keep session focus specific and actionable
- Maintain focus throughout the session - avoid drift to unrelated work
- Update only when explicitly changing session objectives
- Follow the guideline: "Never update this line until we change sessions"

**Chat Entry Guidelines:**
- Add entries in reverse chronological order (newest at top)
- Use consistent formatting for all entries
- **MANDATORY**: All 6 core fields MUST be present: Chat Focus, Chat Objective, What Happened, Key Achievements, Files Created/Modified, Current Implementation Status
- Include comprehensive resource tracking
- Document both successes and failures explicitly
- **MANDATORY**: List ALL files modified (do NOT hide file changes)
- **MANDATORY**: Show status explicitly (what works, what doesn't, what's stuck)
- Provide clear handoff instructions for session continuity

**Token Budget Rule (CRITICAL)**:
- **Token budget is a SESSION-level problem, NOT a field-level problem**
- Do NOT compress fields to save tokens
- Do NOT remove Chat Focus, Objectives, or status tracking
- When session gets too long: **Execute handoff to fresh session** (not field removal)
- Handoff creates new thinking space without losing tracking data
- All archived sessions remain available for reference

**Minimum Line Requirements (ENFORCED)**:
- Chat Focus: 1 line
- Chat Objective: 1 line
- What Happened: 2-4 lines minimum
- Files Created/Modified: ALL files listed (not abbreviated)
- Technical Details: 2-4 lines minimum
- Current Implementation Status: 3-4 items minimum
- Total per chat: 18+ lines minimum (NEVER compress below this)

---

## Field Preservation Rules (Preventing Format Degradation)

**This template enforces protection against the October 2025 field removal crisis**:

✅ **Fields that MUST remain visible in every chat entry**:
1. Chat Focus - Why this chat was needed
2. Chat Objective - What should this chat achieve
3. What Happened - Actions taken
4. Key Achievements - Concrete accomplishments
5. Files Created/Modified - Code accountability
6. Technical Details - What works and what doesn't
7. Current Implementation Status - Progress tracking across chats
8. Handoff Signals - Repetition detection
9. Resources Used - Tool tracking

❌ **Fields that were removed and MUST NOT be removed again**:
- Chat Focus (removed Oct 20, 2025)
- Chat Objective (removed Oct 20, 2025)
- Files Created/Modified (hidden Oct 20, 2025)
- Current Implementation Status (removed Oct 15, 2025)

❌ **Compensatory fields that DON'T solve the problem** (avoid these):
- "Handoff Attempts" - Process tracking, not work data
- "Protocol Violations" - Meta-tracking of compliance
- "Technical Notes" - Too vague, insufficient detail

---

## Format Reevaluation Schedule

Quarterly review of template effectiveness (see `format_reevaluation_protocol.md`):
- **Q1 Review** (Jan 1 - Mar 31): Assess template completeness
- **Q2 Review** (Apr 1 - Jun 30): Evaluate field retention and handoff accuracy
- **Q3 Review** (Jul 1 - Sep 30): Check for format degradation patterns
- **Q4 Review** (Oct 1 - Dec 31): Comprehensive analysis and updates

Changes to this template REQUIRE documented justification and user approval.