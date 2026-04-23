# CSS Themes System — Implementation Plan

## Configuration
- **Artifacts Path**: `.zenflow/tasks/cssthemes-9195`

---

## Agent Instructions

Ask the user questions when anything is unclear or needs their input.

---

## Workflow Steps

### [x] Step: Implementation
<!-- chat-id: cbb2c747-be31-4c63-90e5-52cfdff52935 -->
- Task is complex — plan included below.
- Break down into concrete tasks (incrementable, testable milestones).

**Plan executed:**

#### Model (`Comserv/lib/Comserv/Model/ThemeConfig.pm`)
- [x] Added `set_site_theme` — persists site→theme mapping to `theme_definitions.json`
- [x] Added `create_theme` — creates a new theme entry (with optional base-theme inheritance) and writes its CSS file
- [x] Added `generate_all_theme_css` — regenerates CSS files for every theme in the JSON
- [x] Added `_write_theme_css` — internal helper that writes a single theme's `:root { }` CSS file
- [x] Added `update_theme` — alias for `save_theme`, used by `Admin/Theme.pm`

#### Controller (`Comserv/lib/Comserv/Controller/Admin/Theme.pm`)
- [x] Added `create_theme` route (`/admin/theme/create`, GET+POST) — full form with validation
- [x] Added `details` route (`/admin/theme/details/$theme`, GET)
- [x] Fixed `create_custom_theme` to use the correct `create_theme` call signature

#### Templates
- [x] Replaced `Comserv/root/admin/theme/index.tt` — new 4-step workflow UI (Choose → Modify → Create → Apply)
- [x] Created `Comserv/root/admin/theme/create_theme.tt` — full Theme Creator form with live colour preview

#### Documentation (in-system)
- [x] Created `Comserv/root/admin/documentation/CssThemes.tt` — complete admin guide with overview, step-by-step instructions, CSS variable reference, and FAQ
- [x] Updated `Comserv/root/admin/documentation/Planning.tt` — added CSS Themes workflow section with implementation summary, URL map, data storage notes, and future improvements; added quick-jump link in the navigation

### [x] Step: Testing & Verification
<!-- chat-id: 9af4e981-f5a7-4d53-948f-1cbbed57d396 -->
- Verify `/admin/theme` loads with the new 4-step UI
- Test applying an existing theme to a site
- Test creating a new theme via `/admin/theme/create`
- Test the Quick Custom Theme shortcut
- Verify `CssThemes.tt` documentation renders correctly via the Documentation controller
- Verify Planning.tt shows the new CSS Themes section and jump link

### [x] Step: Bug Fixes & Navigation Improvements
- [x] Fixed duplicate `local-chat.js` inclusion (two footer visual bug) — removed from `layout.tt`, kept in `footer.tt`
- [x] Fixed inspector Close button not syncing pagetop toggle button — added `_syncPagetopToggle()` helper called by `closeInspector()`, `forceCloseInspector()`, and `openInspector()`
- [x] Added "Theme & CSS" submenu to Main admin top navigation (`TopDropListMain.tt`) with links to Theme Manager, Create Theme, Import Theme, and Theme Docs
- [x] Fixed site display name missing from welcome message — extended fallback chain in `pagetop.tt` to include `site_display_name`, `SiteDisplayName`, `SiteName` as direct TT vars before `c.stash.*` accessors

### [x] Step: Background Image & Theme Compliance Fixes (Phase 5)
- [x] CSS cache-busting: set `css_v = time()` in Root.pm auto action, use `c.stash.css_v` in Header.tt
- [x] Merged cssthemes branch to main; all favicon, double-footer, display-name, and theme editor fixes committed
- [x] **Root cause found**: old `/static/css/apis.css` (used as `css_view_name`) was overriding theme variables with stale `repeat-x`, relative URL, and near-white `#FFF8E1` — stripped to site-specific vars only
- [x] Changed `background-attachment` from `fixed` to `scroll` — `fixed` breaks when parent containers have `overflow:hidden` or `backdrop-filter`; `scroll` works universally
- [x] Removed `overflow: hidden` and `backdrop-filter` from admin `.theme-section` (were preventing background from showing)
- [x] Expanded `body.has-bg-image` transparency rules in `theme-overrides.css` to cover documentation sections, status cards, file cards, and `.theme-section`
- [x] Fixed hardcoded `background-color: white` in `documentation.css` → `rgba(255,255,255,0.88)` for semi-transparent cards
- [x] All fixes committed to main (commits e8008fa9, 893f4d55, 0a14b8b5)

### [x] Step: Global .tt Theme Compliance Audit (Phase 1 of systematic audit)
- [x] Updated both template guides (`ApplicationTtTemplate.tt` v0.02, `DocumentationTtTemplate.tt` v0.06) with theme compliance rules
- [x] Global sed pass on all 1308 .tt files: `var(--light-color)` → `rgba(255,255,255,0.15)` (115 files), `var(--secondary-color)` bg → nav-bg or rgba, hardcoded white → rgba(255,255,255,0.88)
- [x] Fixed `#f8f9fa` in FAQ and database_mode; fixed CSC combobox to use CSS vars
- [x] Committed to main (commit 255aefdf — 158 files changed)

### [x] Step: Systematic TT Audit — Wrapper Files (Phase 1)
<!-- chat-id: fdddf1ff-6210-4307-b25a-b9bdd32e90a4 -->
- DB Project 221 (parent), sub-projects 222–226 created
- 25 todos created in DB (P1.1–P5.8) for admin to activate each batch
- Working log: `Documentation/developer/ThemeAuditWorkingLog.tt` (created)
- [x] P1.1 Audit layout.tt — replaced inline `USE date` cache-busting with `c.stash.css_v || '1'` (4 occurrences)
- [x] P1.2 Audit Header.tt — removed 4 duplicate meta tags; replaced inline `USE date` with `cv` for back-to-top.css, back-to-top.js, ai-common.js
- [x] P1.3 Audit pagetop.tt — `.db-env-production` → `var(--warning-color, #dc3545)`; `.db-env-dev` → `var(--success-color, #28a745)`; staging #ffc107 deferred (needs `--caution-color` in Phase 2)
- [x] P1.4 Audit footer.tt — `color: #666` → `var(--text-muted-color, #666)`; `border-top #ddd` → `var(--border-color, #ddd)`; removed duplicate PageVersion (bumped to v0.05)
- [x] P1.5 Audit AdminNotes.tt + SiteAdminNotes.tt — no CSS/styling; no changes needed; noted group-list refactor as future maintenance item

### [x] Step: Systematic TT Audit — CSS Naming Standards (Phase 2)
<!-- chat-id: b01638df-f2c2-4efd-ae57-3c180b42e3f1 -->
- [x] P2.1 Document canonical CSS variable names from all themes/*.css
- [x] P2.2 Normalise CSS element naming in base.css — added --caution-color, --bg-color, --bg-secondary, --card-bg, --text-muted aliases; fixed admin.css --text-muted → --text-muted-color
- [x] P2.3 Update ApplicationTtTemplate.tt v0.03 — added full Canonical CSS Variable Reference section with tables
- [x] P2.4 Update DocumentationTtTemplate.tt v0.07 — updated theme compliance comment with complete canonical variable listing and naming rules

### [x] Step: Systematic TT Audit — Menu System (Phase 3)
<!-- chat-id: da7ff7ff-724f-4225-a340-065aba732d9c -->
- [x] P3.1 All Navigation/TopDropList*.tt files
  - TopDropListWeather.tt: removed deprecated `<font>` tags, removed `<ul>` wrapper, modernised `c.session.group == 'admin'` checks, added semantic CSS classes; bumped to v0.02
  - TopDropListPlanning.tt: inline style verified CSS-var compliant; bumped to v1.1
  - All other TopDropList*.tt: audited — clean, no hardcoded hex colours or deprecated HTML
- [x] P3.2 Navigation/admintopmenu.tt + navigation.tt
  - Both files clean: no hardcoded colours, no deprecated HTML; version strings bumped to record audit

### [x] Step: Systematic TT Audit — Admin Endpoints (Phase 4)
<!-- chat-id: e3fe9155-bc71-41cf-b837-93b167d9fd4e -->
- [x] P4.1 admin/index.tt + admin/documentation/*.tt — fixed background:white/fff, #f8f9fa, text colors, border colors; bumped edit_roles.tt to v1.03
- [x] P4.2 admin/theme/*.tt — fixed editor.tt UI bg colors; data-value defaults left as-is (color pickers)
- [x] P4.3 admin/HardwareMonitor + Logging + backup — fixed card/section bg; semantic alert/status colors left as-is; nav header → var(--nav-bg)
- [x] P4.4 admin/environment_variables + database + schema files — env_vars clean; schema_compare: fixed #000 text → var(--text-color); remaining semantic warning colors left
- [x] P4.5 Remaining admin/*.tt root-level files — global sed pass: background:white/fff/f8f9fa/f5f5f5/fafafa → CSS vars; text #333/#555/#666 → CSS vars; borders #ddd/#dee2e6 → CSS vars; buttons #007bff/#28a745/#dc3545/#6c757d → CSS vars

### [x] Step: Systematic TT Audit — SiteName Templates (Phase 5)
<!-- chat-id: e590d1bc-34a7-4393-ac11-d1ca0cce3e90 -->
- [x] P5.1 BMaster/ + Apiary/ — clean, no changes needed
- [x] P5.2 CSC/ — 11 files fixed (HelpDesk, FAQ, hosting pages)
- [x] P5.3 Shanta/ + WeaverBeck/ + weaverbeck/ + ve7tit/ — 1 file fixed
- [x] P5.4 Forager/ + USBM/ + SB/ + coop/ + ENCY/ — 9 files fixed
- [x] P5.5 WorkShops/ + todo/ + marketplace/ + file/ + ai/ — 44 files fixed
- [x] P5.6 Shop/ + Cart/ + membership/ + Accounting/ + Inventory/ + NetworkMap/ + mail/ — 54 files fixed
- [x] P5.7 Documentation/ — 60+ files fixed
- [x] P5.8 setup/ + include/ + email/ + root-level *.tt — 6 files fixed (email/ excluded: CSS vars unsupported in email clients); pagetop.tt deferred #ffc107 staging bg fixed → var(--caution-color)
