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

## 🔴 MANDATORY FILE NAMING RULE — ENFORCED ON EVERY PROMPT

**ALL new files MUST use PascalCase naming. No exceptions. No reminders required.**

| Type | Correct ✅ | Wrong ❌ |
|------|-----------|---------|
| Template | `EditUser.tt` | `edit_user.tt` |
| Template | `AdminCreateUser.tt` | `admin_create_user.tt` |
| Template | `VerifyEmail.tt` | `verify_email.tt` |
| Perl module | `UserVerification.pm` | `user_verification.pm` |
| Any new file | `MyNewFile.ext` | `my_new_file.ext` |

**Rules**:
- Split words at logical boundaries, capitalize first letter of each word
- No underscores, hyphens, or spaces between words
- Applies to ALL new `.tt`, `.pm`, `.md`, `.yaml`, `.js`, `.css` files
- After creating a file, verify its name is PascalCase before continuing
- If you find yourself writing `snake_case` or `kebab-case` — STOP and correct it

**Template paths in controller code must also use PascalCase**:
```perl
template => 'user/EditUser.tt',       # ✅ CORRECT
template => 'user/edit_user.tt',      # ❌ WRONG
```

Full specification: `coding-standards.yaml` Rule 8 (lines 780-1011)

---

## 🔴 MANDATORY: DocumentConfig.json — NEVER EDIT DIRECTLY

**`DocumentConfig.json` must NEVER be created or edited by AI agents.** This file is managed exclusively by the Documentation system's own code.

**How it works**:
- The Documentation system scans `.tt` files in the `Documentation/` directory
- It reads the `[% META ... %]` block in each file (title, description, roles, TemplateType, category, etc.)
- It builds and updates `DocumentConfig.json` automatically from that metadata
- To trigger a rescan, use the **Refresh** button in the admin UI, or call the API endpoint that activates the documentation refresh code

**Rules for AI agents**:
- ✅ Create/edit `.tt` files in `Documentation/` with correct `META` blocks — the scan picks them up automatically
- ✅ Trigger a documentation refresh via the API if needed after adding new files
- ❌ **NEVER** directly create, edit, or overwrite `DocumentConfig.json`
- ❌ **NEVER** add `DocumentConfig.json` entries by hand — doing so causes git conflicts and breaks the documentation system

---

## 🔴 MANDATORY .tt TEMPLATE STANDARDS — ENFORCED ON EVERY PROMPT

Every new `.tt` file MUST comply with ALL of the following before being considered complete.

### Required Template Structure (audit against `Documentation/ApplicationTtTemplate.tt`)

```
[% META
   title = "Page Title"
   description = "Brief description"
   roles = "admin"              # or appropriate roles
   TemplateType = "Application"
   category = "CategoryName"
   page_version = "0.01"
   last_updated = "YYYY-MM-DD"
%]
[% PageVersion = 'path/TemplateName.tt,v 0.01 YYYY/MM/DD AI Assistant Exp AI Assistant ' %]
[% IF debug_mode == 1 %]
  [% PageVersion %]
[% END %]
```

### TT Syntax Rules (common mistakes that cause parse errors)

```
✅ [% value || 'default' | html %]       # fallback BEFORE filter
❌ [% value | html || 'default' %]       # WRONG — parse error

✅ [% IF items.size > 0 %]              # .size on arrayref
✅ [% item.name | html %]               # filter after value, no chained ||
✅ [% c.flash.error_msg | html %]       # flash access
```

### Flash Message Blocks (REQUIRED in every template with user interaction)

```
[% IF error_msg %]<div class="error">[% error_msg | html %]</div>[% END %]
[% IF c.flash.error_msg %]<div class="error">[% c.flash.error_msg | html %]</div>[% END %]
[% IF c.flash.success_msg %]<div class="success">[% c.flash.success_msg | html %]</div>[% END %]
```

### Theme Compliance (use ONLY global CSS classes — no inline styles except display:none toggles)

- Outer wrapper: `<div class="app-container">`
- Header: `<div class="page-header"><h1>...</h1></div>`
- Content: `<div class="content-container"><div class="content-primary">`
- Sections: `<div class="content-section">`
- Forms: `class="app-form"`, `class="form-section"`, `class="form-row"`, `class="form-field"`, `class="form-input"`
- Actions: `<div class="form-actions">`, buttons: `class="btn btn-primary"` etc.
- Tables: `class="table-container"` → `class="data-table"` → `class="action-cell"`
- Empty state: `<p class="empty-state">No items found.</p>`

### Controller Requirements for Every Template-Rendering Action

```perl
# 1. Always call forward at the end — NEVER omit this
$c->forward($c->view('TT'));

# 2. All database operations MUST be wrapped in eval with IMMEDIATE $@ capture
# CRITICAL: $@ is reset by any subsequent eval (including inside logging/send_error_notification)
# Always stringify and save $@ into a local variable on the very next line after eval
eval { ... };
my $err = "$@" if $@;   # capture and stringify IMMEDIATELY — next line, no exceptions
if ($err) {
    $self->logging->log_with_details($c, 'error', __FILE__, __LINE__, 'action_name',
        "Error description: $err");
    $self->send_error_notification($c, 'Subject', "Error details: $err");
    $c->stash(error_msg => "A friendly error message: $err");
    $c->forward($c->view('TT'));   # show error IN BROWSER — never let it connection-reset
    return;
}
# WRONG — $@ may be empty by the time logging runs:
# eval { ... };
# if ($@) { $self->logging->..($@) }   ← DO NOT DO THIS

# 3. Log every action at info level
$self->logging->log_with_details($c, 'info', __FILE__, __LINE__, 'action_name',
    "Description of what happened");
```

### Error Reporting Rules (NO connection resets allowed)

- **All errors MUST be shown in the browser** via `$c->stash(error_msg => ...)` + `$c->forward($c->view('TT'))`
- **All errors MUST be logged** via `$self->logging->log_with_details($c, 'error', ...)` to `/logs/application.log`
- **Critical errors MUST trigger admin email** via `$self->send_error_notification($c, $subject, $details)`
- **Never let an unhandled exception cause a connection reset** — every action must have top-level eval or error handling

### Logging Levels

| Level | When to use |
|-------|-------------|
| `info` | Normal operations (page load, form submit, record created) |
| `warn` | Non-fatal issues (optional data missing, table not found) |
| `error` | Failures that prevented the operation (DB error, permission denied) |

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
