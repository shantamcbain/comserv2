-- Pages table for Ency schema
-- Simple structure following existing Catalyst patterns
-- Sorted by SiteName and roles for access control

CREATE TABLE IF NOT EXISTS pages_content (
    id INT AUTO_INCREMENT PRIMARY KEY,
    sitename VARCHAR(255) NOT NULL COMMENT 'Site name (CSC, MCOOP, etc.)',
    menu VARCHAR(255) NOT NULL COMMENT 'Menu category (Main, Admin, member, etc.)',
    page_code VARCHAR(255) NOT NULL COMMENT 'Unique page identifier',
    title VARCHAR(255) NOT NULL COMMENT 'Page title',
    body TEXT NOT NULL COMMENT 'Page content body',
    description TEXT NULL COMMENT 'Meta description for SEO',
    keywords TEXT NULL COMMENT 'Meta keywords for SEO',
    link_order INT NOT NULL DEFAULT 0 COMMENT 'Display order in navigation',
    status VARCHAR(50) NOT NULL DEFAULT 'active' COMMENT 'Page status (active, inactive, draft)',
    roles VARCHAR(255) NULL DEFAULT 'public' COMMENT 'Required roles (public, member, admin)',
    created_by VARCHAR(255) NOT NULL COMMENT 'Username who created page',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT 'Creation timestamp',
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT 'Last update timestamp',
    
    -- Constraints
    UNIQUE KEY unique_page_code (page_code),
    
    -- Indexes for common queries
    INDEX idx_sitename_menu (sitename, menu),
    INDEX idx_status (status),
    INDEX idx_roles (roles),
    INDEX idx_link_order (link_order),
    INDEX idx_created_at (created_at)
    
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci 
COMMENT='Pages table for Ency schema - content sorted by SiteName and roles';

-- Insert sample data
INSERT INTO pages_content (sitename, menu, page_code, title, body, description, keywords, link_order, status, roles, created_by) VALUES
('CSC', 'Main', 'home', 'Home', '<h1>Welcome to CSC</h1><p>This is the home page content.</p>', 'CSC Home Page', 'CSC, home, welcome', 1, 'active', 'public', 'admin'),
('CSC', 'member', 'member_dashboard', 'Member Dashboard', '<h1>Member Area</h1><p>Welcome to the member area.</p>', 'Member Dashboard', 'member, dashboard', 1, 'active', 'member', 'admin'),
('MCOOP', 'Main', 'mcoop_home', 'MCOOP Home', '<h1>Welcome to MCOOP</h1><p>MCOOP home page content.</p>', 'MCOOP Home Page', 'MCOOP, cooperative', 1, 'active', 'public', 'admin'),
('CSC', 'Admin', 'admin_panel', 'Admin Panel', '<h1>Administration</h1><p>Admin tools and settings.</p>', 'Admin Panel', 'admin, administration', 1, 'active', 'admin', 'admin');