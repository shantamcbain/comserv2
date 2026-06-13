---
description: "Template Toolkit (.tt) theme compliance — opportunistic fixes on every edit"
globs: ["**/*.tt"]
alwaysApply: true
---

# Template Toolkit & Theme Compliance

**Policy: fix opportunistically** — when you edit a `.tt` file, bring **that file** (or the section you touch) closer to theme compliance. Do **not** run repo-wide theme sweeps unless explicitly requested.

## Canonical references (read before creating or heavily editing)

| Page type | Base template (in-app docs) |
|-----------|----------------------------|
| Application pages (`root/admin/`, `root/todo/`, etc.) | `/Documentation/ApplicationTtTemplate` |
| Documentation pages (`root/Documentation/`) | `/Documentation/DocumentationTtTemplate` |

Live files:
- `Comserv/root/Documentation/ApplicationTtTemplate.tt`
- `Comserv/root/Documentation/DocumentationTtTemplate.tt`

CSS variable source of truth: `Comserv/root/static/css/base.css` and `theme_definitions.json`.

---

## Opportunistic checklist (apply when editing any `.tt`)

### 1. Structure
- [ ] Application pages: wrap in `app-container` → `page-header` → `content-container` (see Application template)
- [ ] Documentation pages: use `container` → `row` → `col-*` grid (see Documentation template)
- [ ] Forms: `app-form`, `form-section`, `form-row`, `form-field`, `form-actions`
- [ ] Tables: `table-container` + `data-table` (app) or themed `<table>` with `var(--table-header-bg)` (docs)
- [ ] Buttons: `btn btn-primary` / `btn-secondary` / `btn-sm` — not ad-hoc styled `<button>`

### 2. Theme variables (replace while editing)
- [ ] **No hardcoded colours** in inline styles (`#fff`, `#333`, `rgb(...)`) → `var(--text-color)`, `var(--border-color)`, etc.
- [ ] **No invented variable names** — use canonical names from ApplicationTtTemplate § Canonical CSS Variable Reference
- [ ] Text: `var(--text-color)`, muted: `var(--text-muted-color)`
- [ ] Links: `var(--link-color)` / `var(--link-hover-color)`
- [ ] Alerts: `var(--success-color)`, `var(--warning-color)`, `var(--info-color)`

### 3. Background-image themes (`has-bg-image` — BMaster, apis, etc.)
Fix these when you see them in a file you are already editing:
- [ ] Page wrappers: `transparent` or `rgba(255,255,255,0.12)` — not opaque white blocks
- [ ] Readable cards: `rgba(255,255,255,0.88)` for content that needs contrast
- [ ] **Never** `overflow: hidden` on full-page section containers
- [ ] **Never** `backdrop-filter` on structural wrappers
- [ ] **Never** `background-attachment: fixed`
- [ ] **Avoid** `var(--secondary-color)` for large area backgrounds (can be very dark per theme)

### 4. Documentation-specific
- [ ] Links: `/Documentation/FILENAME` — no subdirs, no `.tt` extension (see DocumentationTtTemplate footer notes)
- [ ] Section anchors + TOC pattern for long docs
- [ ] Inline styles must still use CSS variables (Documentation template pattern)

### 5. Scope discipline
- [ ] Fix the section you changed **plus** obvious violations in the same file
- [ ] Do **not** expand scope to unrelated templates
- [ ] Do **not** add page-specific `<style>` blocks — prefer global classes or variables
- [ ] Preserve behaviour; this is visual/structural compliance only

---

## Quick smell test (grep while editing)

When touching a file, scan for these and fix matches in your edit scope:

```
style="[^"]*#[0-9a-fA-F]{3,6}     # hardcoded hex in inline style
style="[^"]*background:\s*white     # non-themed background
style="[^"]*color:\s*#             # hardcoded text colour
overflow:\s*hidden                  # on page-level wrappers
backdrop-filter:                    # on structural wrappers
background-attachment:\s*fixed
```

---

## Per-site consistency

Themes are selected per site (`Site` / `ThemeConfig`). Compliance means the **same** `.tt` file renders correctly on CSC, USBM, apis/BMaster, dark, etc. If a change looks right on one site only, use CSS variables — not site-specific inline colours.

---

## When to do a focused pass (optional)

Like logging gaps, a **targeted** theme pass is warranted only when:
- A page is reported broken on a specific site theme
- You are already doing a major redesign of that controller/template pair

Otherwise: **each edit makes one file better** until coverage is broad.