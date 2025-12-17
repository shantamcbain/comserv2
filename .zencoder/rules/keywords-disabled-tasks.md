---
description: "Disabled task keywords for tasks waiting on application availability"
alwaysApply: false
---

# Zencoder Disabled Task Keywords - Waiting for Application Availability

**Purpose**: Task-specific keywords currently disabled due to Docker/application connectivity issues

**Last Updated**: Thu Dec 11 2025  
**Version**: 1.0 (Modular version - extracted from keywords.md)

**Current Disability Reason**: Docker connectivity issue prevents browser operations and application access

---

## Quick Reference Table (DISABLED KEYWORDS)

| Keyword | Format | Status | Cost | Purpose |
|---------|--------|--------|------|---------|
| `/checktodos` | `/checktodos` | 🚫 Disabled | High | Todo priority list (app unavailable) |
| `/dotodo` | `/dotodo` | 🚫 Disabled | High | Start todo (app unavailable) |
| `/createnewtodo` | `/createnewtodo` | 🚫 Disabled | High | Create todo (app unavailable) |
| `/createnewproject` | `/createnewproject` | 🚫 Disabled | High | Create project (app unavailable) |

---

## DISABLED KEYWORD DEFINITIONS

### 1. `/checktodos` - Priority Todo List

**Status**: 🚫 Disabled | **Cost**: High (browser operations) | **Format**: `/checktodos`

**Current Status**: Application not accessible due to Docker connectivity issue. Keyword will be available when application is restored.

**Original Purpose**: Return 10 most important todos across application (prioritized by overdue → due date → priority → status)

**Original Workflow** (when available):
- Execute `/checktodos` at start of new session to identify priority work
- Access http://workstation.local:3001/todo
- Display prioritized list to guide session planning

**When Available**: Will execute when application restored and browser operations resume

---

### 2. `/dotodo` - Start Todo Work

**Status**: 🚫 Disabled | **Cost**: High (browser operations) | **Format**: `/dotodo`

**Current Status**: Application not accessible. Keyword will be available when app restored.

**Original Purpose**: Start work on specific todo, create time log, transition todo status

**Original Workflow** (when available):
1. Find todo in browser list
2. Navigate to it
3. Update status to 'in progress'
4. Create log entry
5. Add comments if provided
6. Execute `/chathandoff` with prompt for next session

**When Available**: Will follow full browser-based workflow

---

### 3. `/createnewtodo` - Create New Todo

**Status**: 🚫 Disabled | **Cost**: High (browser operations) | **Format**: `/createnewtodo`

**Current Status**: Application not accessible due to Docker connectivity issue.

**Original Purpose**: Create new comprehensive todo with plan and subtodos

**Original Workflow** (when available):
1. Gather requirements
2. Create comprehensive plan (MVC layers)
3. Present plan for approval
4. Create todo in browser interface
5. Create subtodos if needed
6. Link to session tracking

**When Available**: Will follow full workflow with browser-based todo creation

---

### 4. `/createnewproject` - Create New Project

**Status**: 🚫 Disabled | **Cost**: High (browser operations) | **Format**: `/createnewproject`

**Current Status**: Application not accessible due to Docker connectivity issue.

**Original Purpose**: Create new project in Comserv application

**Original Workflow** (when available):
1. Gather requirements
2. Create comprehensive plan
3. Navigate to project creation form
4. Fill project details
5. Submit form
6. Update session tracking

**When Available**: Will follow full browser-based project creation workflow

---

## Restoration Timeline

**Restoration Timeline**: When Docker connectivity restored and application accessible again

**Workaround Strategy**: Use file-based keywords only (`/chathandoff`, `/sessionhandoff`, `/validatett`, `/updateprompt`) until app restored

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-11 | Extracted disabled keywords from keywords.md into modular structure; documented Docker connectivity status |

