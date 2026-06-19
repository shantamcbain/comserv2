-- Per-SiteName (or 'All') customizations and adoptions of CSC menu_stock items.
-- Also used for site-specific pure custom items that are "promoted" or new top-levels in future.
--
-- When a site admin "includes" or "overrides" a stock item in the menu editor, a row is created here.
-- The effective menu builder (Navigation.pm) merges:
--   stock (CSC truth) + overrides (site labels/icons/placement/include decisions + page context) + existing internal_links_tb (user private + legacy public customs)
--
-- page_pattern: NULL or '' = global (all pages). Otherwise simple prefix match or glob (e.g. '/brew*', '/shop/', '/HelpDesk') used by builder to decide visibility/override application for current page.
-- Editor prompts "for this page only or globally?" and sets the pattern accordingly.
-- is_included: for non-always_include stock, controls whether this site uses the item.
-- For always_include stock, the row may still exist for the overrides (label etc.) and renderer forces presence.
--
-- Pure customs (no stock_id) allowed here for future expansion (custom top menus etc.), but current "add link" flow continues to use internal_links_tb for minimal disruption.

CREATE TABLE IF NOT EXISTS site_menu_overrides (
    id INT NOT NULL AUTO_INCREMENT,
    site_name VARCHAR(50) NOT NULL DEFAULT 'All' COMMENT 'SiteName or All',
    stock_id INT NULL COMMENT 'Reference to menu_stock.id; NULL for pure site custom (rare in v1)',
    stock_key VARCHAR(64) NULL COMMENT 'Denormalized for easy lookup / if stock row deleted',
    custom_label VARCHAR(120) NULL COMMENT 'Override; if NULL use stock default_label',
    custom_url VARCHAR(500) NULL,
    custom_icon VARCHAR(64) DEFAULT '',
    custom_category VARCHAR(50) NULL COMMENT 'Allow moving the item to a different menu category',
    custom_submenu VARCHAR(64) DEFAULT '',
    sort_order INT NOT NULL DEFAULT 100,
    is_included TINYINT(1) NOT NULL DEFAULT 1 COMMENT 'For optional stock: whether site includes it. Forced true for always_include.',
    page_pattern VARCHAR(255) DEFAULT NULL COMMENT 'NULL=global for all pages on site. Otherwise context rule e.g. "/brew*" or exact path prefix. Editor sets based on current page.',
    is_page_specific TINYINT(1) NOT NULL DEFAULT 0,
    notes TEXT,
    created_by VARCHAR(100),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_site_stock (site_name, stock_id),  -- one override per stock per site
    KEY idx_site_menu_overrides_site (site_name),
    KEY idx_site_menu_overrides_stock (stock_id),
    KEY idx_site_menu_overrides_pattern (page_pattern)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='SiteName customizations of CSC stock + limited pure customs. Drives DB-dominated editable menus.';

-- Note: Migration + seeder create the stock. Site rows are created on-demand by the menu editor when a site admin first touches a stock item or runs "migrate my menus".
