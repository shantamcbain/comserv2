-- CSC / Central stock menu items for the new DB-dominated menu system.
-- SiteName admins customize via site_menu_overrides (references to these).
-- Core items (login, HelpDesk basics, main home, admin for admins) may have hard-coded .tt fallbacks
-- for resilience, but are also represented here so they can be presented in the editor
-- and overridden (rename, reorder where allowed) by sites.
--
-- CSC admins manage these (CRUD + flags). Non-CSC see them as read-only "stock palette".
--
-- Gating and mandatory behavior:
--   always_include: 1 = forcibly part of the site's effective menu (renderer ensures presence)
--   always_visible: 1 = always shown (no role/page hiding for this item)
--   reorderable: 1 = site admin can change its position in the list
-- gating: simple flags string for now e.g. "module:beekeeping" or "subscription" or "csc_only".
--   Matches/extends existing logic in Navigation.pm @NAV_MENU_CATALOG and hosted_nav_visible etc.
--
-- Run this (or rely on on-demand ensure in Navigation controller + seeder).
-- Seeder (seed_csc_menu_stock) is idempotent and populates from this "truth".

CREATE TABLE IF NOT EXISTS menu_stock (
    id INT NOT NULL AUTO_INCREMENT,
    stock_key VARCHAR(64) NOT NULL COMMENT 'Stable unique key e.g. main_home, helpdesk_submit_ticket, admin_git_pull',
    default_label VARCHAR(120) NOT NULL,
    default_url VARCHAR(500) NOT NULL,
    default_icon VARCHAR(64) DEFAULT '' COMMENT 'e.g. icon-home, icon-ticket (from svg-icons system)',
    default_category VARCHAR(50) NOT NULL COMMENT 'Main_links, HelpDesk_links, Admin_links, etc. Matches NAV_MENU_CATALOG',
    default_submenu VARCHAR(64) DEFAULT '' COMMENT 'top, resources, admin_links, etc. Matches nav_submenu or legacy sections',
    always_include TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'CSC: must be in every site''s effective menu',
    always_visible TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'CSC: always shown (ignore some role/page hides)',
    reorderable TINYINT(1) NOT NULL DEFAULT 1 COMMENT 'CSC: site admins may change sort order of this item',
    gating VARCHAR(255) DEFAULT '' COMMENT 'e.g. "module:beekeeping" or "csc_only;subscription" or "requires_shop". Parser in builder.',
    sort_hint INT NOT NULL DEFAULT 100,
    description TEXT,
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_menu_stock_key (stock_key),
    KEY idx_menu_stock_category (default_category),
    KEY idx_menu_stock_active (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='Canonical CSC-provided stock menu items. Sites reference/override via site_menu_overrides.';

-- Seed note: Actual initial rows are inserted by the seeder in Navigation.pm (seed_csc_menu_stock)
-- or script/seed_menu_stock.pl so it can be re-run safely and evolve.
-- Example core seeds (illustrative; seeder has the real authoritative list derived from TopDropLists):
-- INSERT INTO menu_stock (stock_key, default_label, default_url, default_icon, default_category, default_submenu, always_include, always_visible, reorderable, gating, sort_hint, description) VALUES
-- ('main_home', 'Home', '/', 'icon-home', 'Main_links', 'top', 1, 1, 1, '', 10, 'Core fallback-safe home'),
-- ('helpdesk_submit', 'Submit a Ticket', '/HelpDesk/ticket/new', 'icon-ticket', 'HelpDesk_links', 'top', 1, 1, 1, '', 20, 'Key support entry'),
-- ... ;
