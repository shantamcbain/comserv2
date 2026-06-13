---
description: "Template Toolkit (.tt) theme compliance — opportunistic fixes on every edit"
globs: ["**/*.tt"]
alwaysApply: true
---

# Template Toolkit & Theme Compliance

## Two distinct goals (do not conflate)

| Goal | What you are doing | Where to work | Primary reference |
|------|-------------------|---------------|-------------------|
| **A — Theme authoring** | Create or change how a site *looks* (colours, fonts, site mapping) | `Comserv/root/static/config/theme_definitions.json` → generated CSS | `/Documentation/CssThemes`, `/Documentation/ThemeConfig` |
| **B — Template compliance** | Make a `.tt` page render correctly on *every* theme | The `.tt` file you are editing | This file + base templates below |

**This rule file is about Goal B.** Goal A is JSON + `ThemeConfig`; templates never define theme colours directly.

### Goal A — Create or change a theme (summary)

1. **Canonical source:** `Comserv/root/static/config/theme_definitions.json`
2. **Structure:**
   - `themes.{theme_id}.variables` — keys like `primary-color` (no `--` prefix; CSS emits `--primary-color`)
   - `site_themes.{site}` — maps lowercase site name → theme id (e.g. `bmaster` → `apis`)
3. **Generated output:** `Comserv/root/static/css/themes/{theme_id}.css` — written by `ThemeConfig::_write_theme_css`; treat as build artefact, not hand-edited source of truth
4. **Defaults:** `Comserv/root/static/css/base.css` (`:root` variables)
5. **Admin UI:** `/admin/theme` (`Comserv::Controller::Admin::Theme` + `Comserv::Model::ThemeConfig`)
6. **Regenerate CSS** after JSON edits: `ThemeConfig->generate_all_theme_css($c)` or save via admin UI
7. **Legacy (avoid):** `Comserv::Model::Theme` (DB) and `ThemeAdmin` controller — use `ThemeConfig` + `/admin/theme`

### Goal B — Template theme compliance (this file)

**Policy: fix opportunistically** — when you edit a `.tt` file, bring **that file** (or the section you touch) closer to theme compliance. Do **not** run repo-wide theme sweeps unless explicitly requested.

Templates use **canonical CSS variables** from `base.css`, overridden per theme via generated CSS. Compliance means the same `.tt` renders on CSC, USBM, apis/BMaster, dark, etc.

---

## Canonical references (read before creating or heavily editing)

| Page type | Base template (in-app docs) |
|-----------|----------------------------|
| Application pages (`root/admin/`, `root/todo/`, etc.) | `/Documentation/ApplicationTtTemplate` |
| Documentation pages (`root/Documentation/`) | `/Documentation/DocumentationTtTemplate` |

Live files:
- `Comserv/root/Documentation/ApplicationTtTemplate.tt`
- `Comserv/root/Documentation/DocumentationTtTemplate.tt`

Variable names: `Comserv/root/static/css/base.css` (defaults) and `themes.*.variables` in `static/config/theme_definitions.json` (overrides).

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
- [ ] Readable cards only: `rgba(255,255,255,0.88)` for small content areas needing contrast — **not** full-page wrappers
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

Themes are selected per site via `site_themes` in `theme_definitions.json` (`ThemeConfig::get_site_theme`). Compliance means the **same** `.tt` file renders correctly on CSC, USBM, apis/BMaster, dark, etc. If a change looks right on one site only, use CSS variables — not site-specific inline colours.

---

## When to do a focused pass (optional)

Like logging gaps, a **targeted** theme pass is warranted only when:
- A page is reported broken on a specific site theme
- You are already doing a major redesign of that controller/template pair

Otherwise: **each edit makes one file better** until coverage is broad.