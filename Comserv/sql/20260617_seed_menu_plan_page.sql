-- Living DB page for the Menu System Upgrade Plan.
-- This is a "db page" (stored in the `page` table with inline `body`).
-- It is fully editable by admins via the normal /pages/edit UI or the pages list.
-- View at: /page/menu-system-upgrade-plan
--
-- Why a DB page? So the team can collaboratively review, update status,
-- add implementation notes, checklists, and observations as the code changes
-- in the major menu migration (CSC stock + site overrides + context-aware lists).
--
-- Run this SQL (mysql or via your deploy tools) to seed or re-seed the page.
-- It is idempotent via ON DUPLICATE KEY UPDATE on the unique (sitename, page_code).
--
-- The page is placed in the Admin menu so it is easily reachable from admin contexts.
-- Link to it is added on the main menu edit page (manage_links).

SET @sitename = 'CSC';
SET @page_code = 'menu-system-upgrade-plan';
SET @title = 'Menu System DB Migration & Upgrade Plan (2026) - Living Document';
SET @menu = 'Admin';
SET @status = 'active';
SET @roles = 'admin';  -- Restrict to admins for the planning doc; change to 'public' or '' if desired
SET @body = '
<h1>Menu System DB Migration &amp; Upgrade Plan (2026)</h1>

<p><strong>⚠️ LIVING DOCUMENT</strong> — Edit this page directly in the CMS (title, body, etc.) to track progress, add notes, update checklists, and record decisions as we implement the changes. This is the single source of truth for the team during the migration.</p>

<p><strong>Page Code:</strong> menu-system-upgrade-plan &nbsp;|&nbsp; <strong>View:</strong> <a href="/page/menu-system-upgrade-plan">/page/menu-system-upgrade-plan</a></p>

<h2>Goal (from original request)</h2>
<p>Convert to a <strong>DB-dominated menu system</strong> (with hybrid resilience). CSC provides the base/mandatory stock lists and items (Main, Login, HelpDesk, Admin, etc.). SiteName admins rename items, change list appearance/order <em>according to the page they are on</em>, and are always presented with the full CSC stock when editing. All styles come from the chosen SiteName theme. Some core items remain hard-coded in templates for fallback if the DB is unavailable.</p>

<h3>Key Clarifications (Incorporated)</h3>
<ul>
  <li><strong>Resilience</strong>: Login, basic HelpDesk, key Main links, support/home must have hard-coded .tt fallbacks. Home is DB-by-default but offer “convert to DB editable”.</li>
  <li><strong>Renaming</strong>: Key items (login, HelpDesk menu, a few others) stay hard-coded; most others + everything new are DB-driven and renamable by SiteName admin.</li>
  <li><strong>Per-page list appearance</strong>: Feature/module filtering (e.g. on brewing pages emphasize shop-related, de-emphasize others), reorder (drag &amp; drop), visibility/position per page. The editor must be page-aware and ask “apply to this page only or globally?”</li>
  <li><strong>Mandatory / always</strong>: CSC admin can mark stock items with: always included, always visible, movable (reorderable). Examples: Admin dropdown always visible to admins on all pages; Main/login always; weather movable &amp; visible-if-subscribed; beekeeping only-if-subscribed/module.</li>
  <li><strong>Custom top-levels</strong>: Allowed (“all”).</li>
  <li><strong>Editor UX</strong>: When editing a menu, present <strong>all CSC stock items</strong> for include/override/rename.</li>
  <li><strong>Theming</strong>: 100% from the SiteName’s chosen theme (CSS variables only).</li>
</ul>

<h2>High-Level Phases &amp; Progress</h2>

<h3>Phase 1: Foundations &amp; Schema (COMPLETE — 2026-06-16)</h3>
<ul>
  <li>✅ New tables: menu_stock (CSC canonical stock with always_include/always_visible/reorderable/gating) + site_menu_overrides (per-site renames, includes, page_patterns, sort_order).</li>
  <li>✅ DBIC Result classes + registration in Ency schema.</li>
  <li>✅ Runtime ensure + idempotent seeder in Navigation.pm (core stock items covering Main/HelpDesk/Admin + gated examples).</li>
  <li>✅ populate_navigation_data now loads csc_stock_catalog + effective items into stash (for editor &amp; future render).</li>
  <li>✅ Migrations in sql/ + syntax verified.</li>
  <li>Next in phase: full context builder, gating enforcement, cache invalidation hooks.</li>
</ul>

<h3>Phase 2: Editor &amp; Stock Browser (IN PROGRESS / NEXT)</h3>
<ul>
  <li>Enhance /navigation/manage_links (and related) to show a “Browse CSC Stock” palette with <strong>all</strong> stock items, badges for mandatory/gating, “Include / Override” actions.</li>
  <li>Override form: custom label, icon (from existing icon system), placement, include toggle (locked for mandatory), sort order.</li>
  <li>Drag &amp; drop ordering (JS) persisted to overrides.</li>
  <li>Page-aware editing: detect current page, prompt “global or for this page (set page_pattern)?”.</li>
  <li>“Convert this hard-coded section to DB” helper.</li>
  <li>CSC-only stock management UI (/navigation/manage_stock or under Admin).</li>
  <li><strong>Link to this plan page added on the menu edit page</strong> (this task).</li>
</ul>

<h3>Phase 3: Context / Page Awareness + Gating</h3>
<ul>
  <li>Builder that respects current page path, enabled_modules, membership/subscription state, page_pattern on overrides.</li>
  <li>Filter / reorder / hide items contextually (e.g. brewing feature page).</li>
  <li>Enhance effective getters and stash.</li>
</ul>

<h3>Phase 4: Rendering Integration + Theming Audit + Custom Top Menus</h3>
<ul>
  <li>Update TopDropList*.tt + inc/ partials + pagetop to prefer effective DB data for customizable sections while keeping core hard-coded fallbacks.</li>
  <li>Support for site-created custom top-level dropdowns.</li>
  <li>Full CSS var audit — no hard-coded colours left in nav templates.</li>
  <li>“Promote to DB” one-click migration helper for existing sites.</li>
</ul>

<h3>Phase 5: Migration Tools, Polish, Testing, Docs, Cutover</h3>
<ul>
  <li>Apply seed SQLs on real DBs.</li>
  <li>Manual testing across guests/admins, multiple SiteNames, module on/off, page contexts.</li>
  <li>Update MenuSystem.tt, developer docs, admin guides.</li>
  <li>Deprecate direct template SQL queries for nav.</li>
  <li>Optional full dynamic renderer component later.</li>
</ul>

<h2>Architectural Notes (Update as Decisions Evolve)</h2>
<p>See the original detailed plan for trade-offs (separate stock vs overrides tables chosen for clean CSC ownership; hybrid render for resilience; etc.).</p>
<p><strong>Current implementation pointers (update this section as we code):</strong></p>
<ul>
  <li>Core logic: lib/Comserv/Controller/Navigation.pm (ensure, seeder, getters, populate integration)</li>
  <li>Models: lib/Comserv/Model/Schema/Ency/Result/{MenuStock.pm, SiteMenuOverride.pm}</li>
  <li>Schema registration: lib/Comserv/Model/Schema/Ency.pm</li>
  <li>Migrations: sql/20260617_create_menu_stock.sql and ..._site_menu_overrides.sql</li>
  <li>Menu management UI: root/Navigation/manage_links.tt (and add/edit/manage_submenus)</li>
  <li>This plan page itself: created via the seed below + linked from menu edit page.</li>
</ul>

<h2>Risks &amp; Mitigations (Living)</h2>
<ul>
  <li>Menu breakage on live sites → phased, fallbacks, per-site promote, extensive testing.</li>
  <li>Complexity of context/merge → implement incrementally; start global, add page scope next.</li>
  <li>Performance → keep/extend the existing per-(site+user) cache; invalidate on stock/override changes.</li>
</ul>

<h2>Implementation Notes &amp; Decisions Log (EDIT THIS SECTION FREELY)</h2>
<p><em>Add date-stamped notes here as you implement. Example:</em></p>
<ul>
  <li><strong>2026-06-16</strong>: Phase 1 foundation complete. Seeder has ~20 core stock items with correct always_* and gating flags. Tables auto-create on first populate (following nav_submenu pattern). Link to this plan added on manage_links. Ready for Phase 2 editor work.</li>
  <li><strong>[Your note here]</strong> ...</li>
</ul>

<h2>Next Immediate Steps</h2>
<ol>
  <li>Apply the seed SQL (this file) so the page exists and is editable.</li>
  <li>Continue Phase 2: build the stock browser + override form in the menu management UI.</li>
  <li>Update the checklist above as phases complete.</li>
  <li>Keep this page as the review artifact for the team.</li>
</ol>

<p>— End of living plan. Edit the body above to keep it current.</p>
';

-- Idempotent insert / update for the page record (uses the page table which stores body directly and is used by the CMS + /page/ routes + nav).
INSERT INTO page (sitename, menu, page_code, title, body, status, roles, link_order, page_type, created_by, created_at, updated_at)
VALUES (@sitename, @menu, @page_code, @title, @body, @status, @roles, 999, 'standard', 'system-plan-seed', NOW(), NOW())
ON DUPLICATE KEY UPDATE
    title = VALUES(title),
    body = VALUES(body),
    status = VALUES(status),
    roles = VALUES(roles),
    menu = VALUES(menu),
    updated_at = NOW();

-- Optional: also seed a parallel pages_content row (for documentation/ency-style usage if the system references it).
-- This makes the content available in both storage mechanisms used in the codebase.
INSERT INTO pages_content (sitename, page_code, title, body, menu, status, roles, link_order, created_at, updated_at)
VALUES (@sitename, @page_code, @title, @body, @menu, @status, @roles, 999, NOW(), NOW())
ON DUPLICATE KEY UPDATE
    title = VALUES(title),
    body = VALUES(body),
    menu = VALUES(menu),
    status = VALUES(status),
    roles = VALUES(roles),
    updated_at = NOW();

SELECT 'Menu System Upgrade Plan page seeded/updated successfully. View at /page/menu-system-upgrade-plan' AS result;