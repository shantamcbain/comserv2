---
description: "Zencoder adapter — Template Toolkit theme compliance (canonical docs in-app)"
globs: ["**/*.tt"]
alwaysApply: true
---

# Template / Theme Standards (Zencoder adapter)

**Canonical source:** `/Documentation/DevelopmentStandards` and the base templates below.  
This file exists only so Zencoder auto-applies rules on `*.tt` edits. Do not duplicate or extend content here.

## Read first

| Topic | Canonical doc (in-app or repo) |
|-------|-------------------------------|
| Standards index | `/Documentation/DevelopmentStandards` |
| Theme authoring (Goal A) | `/Documentation/CssThemes`, `/Documentation/ThemeConfig` |
| Application `.tt` (Goal B) | `/Documentation/ApplicationTtTemplate` |
| Documentation `.tt` (Goal B) | `/Documentation/DocumentationTtTemplate` |
| CSS variable defaults | `Comserv/root/static/css/base.css` |
| Theme JSON | `Comserv/root/static/config/theme_definitions.json` |
| YAML consolidation | `Comserv/root/coding-standards-comserv.yaml` |

## Goal B quick reminder (when editing `.tt`)

- Fix opportunistically in the file you touch — no repo-wide sweeps
- No hardcoded colours → `var(--text-color)`, `var(--border-color)`, etc.
- Application: `app-container`, `content-container`, `btn btn-*`, `data-table`
- Documentation: `container` / `row` / `col-*`; links `/Documentation/FILENAME` (no subdirs, no `.tt`)
- `has-bg-image`: transparent or `rgba(255,255,255,0.12)` on wrappers; `0.88` on small cards only

Full checklist: **ApplicationTtTemplate** and **DocumentationTtTemplate** comment blocks + `/Documentation/DevelopmentStandards`.