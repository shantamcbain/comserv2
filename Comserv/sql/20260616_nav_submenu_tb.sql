-- Dynamic navigation submenu sections (per menu category + site scope).
-- System rows (is_system=1) are seeded from NAV_SUBMENU_CATALOG; site admins may add custom rows.

CREATE TABLE IF NOT EXISTS nav_submenu_tb (
    id INT NOT NULL AUTO_INCREMENT,
    category VARCHAR(50) NOT NULL COMMENT 'Parent menu category e.g. Admin_links',
    sitename VARCHAR(50) NOT NULL DEFAULT 'All' COMMENT 'Site scope or All',
    submenu_id VARCHAR(64) NOT NULL COMMENT 'Slug stored on internal_links_tb.submenu',
    label VARCHAR(120) NOT NULL,
    icon VARCHAR(64) DEFAULT '',
    header_url VARCHAR(255) DEFAULT '' COMMENT 'Optional submenu header link',
    section_order INT NOT NULL DEFAULT 0,
    is_system TINYINT(1) NOT NULL DEFAULT 0 COMMENT '1=seeded/built-in',
    template_slot VARCHAR(64) DEFAULT '' COMMENT 'Maps to legacy template section during migration',
    status TINYINT(1) NOT NULL DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_nav_submenu_scope (category, sitename, submenu_id),
    KEY idx_nav_submenu_category (category),
    KEY idx_nav_submenu_sitename (sitename),
    KEY idx_nav_submenu_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;