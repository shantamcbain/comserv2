---
description: Repository Information & Zencoder Enforcement Rules
alwaysApply: true
version: "2.2"
last_updated: "2026-01-24"
enforcement_status: "🔴 CRITICAL - Mandatory for all Zencoder agents"
---

# Comserv Application & Zencoder Standards (MANDATORY)

## ⚠️ CRITICAL ENFORCEMENT NOTICE

**This document is MANDATORY reading for ALL Zencoder agents.** Non-compliance results in:
- 🔴 Work HALTED by validation_step0.pl
- 🔴 Chat continuation BLOCKED
- 🔴 /chathandoff execution REQUIRED
- 🔴 Violation escalation to human review

---

## Part 1: Repository Information

**NOTE**: Detailed repository structure, language specifications, and dependencies have been migrated to the **SINGLE SOURCE OF TRUTH**.

### 📌 PRIMARY REFERENCE: `/.zencoder/coding-standards.yaml`

See **REPOSITORY OVERVIEW** (lines 14-48) in `coding-standards.yaml` for:
- Full directory structure
- Language & Runtime (Perl 5.40.0, Catalyst)
- Docker & Containerization details
- Database & Caching specifications
- Build, Installation, and Testing guides
- Main Entry Points and Configuration files

---

## Part 2: ZENCODER MANDATORY STANDARDS (All Agents) - CONSOLIDATED REFERENCE

### ⚠️ CONSOLIDATION NOTICE (2026-01-16)

**EFFECTIVE IMMEDIATELY**: All Zencoder enforcement rules (formerly Rules Z1-Z4 below) have been **consolidated into a single source of truth** in:

### 📌 PRIMARY REFERENCE: `/.zencoder/coding-standards.yaml`

All agents MUST read the following sections from coding-standards.yaml:

| Zencoder Standard | Location | Coverage |
|---|---|---|
| **CRITICAL SETTINGS** | Lines 51-93 | Documentation paths (PascalCase filenames, /Documentation/ URL format) |
| **GLOBAL ENFORCEMENT PROTOCOL** | Lines 95-115 | Automatic validation gates (ask_questions, /updateprompt enforcement) |
| **GLOBAL RULES 1-10** | Lines 117-1230 | ask_questions(), /updateprompt, startup protocol, keyword execution, role tag conflicts, bilateral audit trail, PascalCase, RoleSpec integrity, Documentation standards |
| **KEYWORDS** | Lines 1231-1393 | /chathandoff, /sessionhandoff, /validatett definitions and protocols |
| **AGENTS SECTION** | Lines 1395+ | Consolidated agent specifications (Cleanup Agent, Docker Agent, others) |

### Legacy Rules Z1-Z4 (All Content Merged into coding-standards.yaml)

| Legacy Rule | Mapped To | Description |
|---|---|---|
| **Rule Z1: Tool Responsibility Boundaries** | Rule 6: External Role Tag Conflict Resolution (lines 599-659) + Rule 8: PascalCase Filenames (lines 780-1011) | Tool scope, file management, constraints |
| **Rule Z2: Reference Consolidation** | Rule 4: Startup Protocol (lines 516-554) + metadata section (lines 1-11) | Single source of truth, enforcement hierarchy |
| **Rule Z3: Compliance Protocol** | Rule 2: /updateprompt Workflow Gate (lines 244-496) + Rule 1: ask_questions (lines 153-242) + Rule 7: Bilateral Audit Trail (lines 660-778) | Phase sequence, execution workflow, audit logging |
| **Rule Z4: Documentation Centralization** | Rule 8: PascalCase Filename Convention (lines 780-1011) + CRITICAL SETTINGS (lines 51-93) | File creation, path format, consolidation requirement |

### ✅ What This Means for Agents

1. **STOP referencing repo.md for rules** - Use coding-standards.yaml instead
2. **Repository context (Part 1 above)** - Still available in this file for quick reference
3. **All enforcement** - Now centralized in coding-standards.yaml with unified numbering system (Rules 1-8)
4. **Deprecated .md files** - Archived with redirect stubs (see table below)

### ARCHIVED FILES WITH REDIRECTS

The following files are ARCHIVED effective 2026-01-15. Redirect stubs created at original locations:

| File | Reason | Archive Location | Redirect Status |
|------|--------|------------------|---|
| `zencoder-context-configuration.md` | Content merged into coding-standards.yaml | `.zencoder/rules/archive/` | ✅ Redirect stub |
| `keywords.md` v1.0 | Refactored into modular structure | `.zencoder/rules/archive/` | ✅ Redirect stub |
| `CRITICAL_AGENT_BOUNDARIES.md` | Content merged into coding-standards.yaml Rule 6 | `.zencoder/rules/archive/` | ✅ Redirect stub |
| `DAILY_PLAN_AUTOMATOR_*.md` (variants) | Specs moved to coding-standards.yaml agents section | `.zencoder/rules/archive/` | ✅ Redirect stubs |
| `documentation-synchronization-agent.md` | Specs consolidated into coding-standards.yaml | `.zencoder/rules/archive/` | ✅ Redirect stub |

**See also**: `/Comserv/root/Documentation/session_history/AI_ASSISTANTS_IDE_INTEGRATION_AUDIT.md` for consolidation history and audit trail.

---

**CONSOLIDATED ON**: 2026-01-16 by Cleanup Agent (Chat 64, Prompt 103)  
**STATUS**: ✅ All Rules unified in coding-standards.yaml  
**NEXT STEP**: Update all external references to point to coding-standards.yaml lines (see table above)
