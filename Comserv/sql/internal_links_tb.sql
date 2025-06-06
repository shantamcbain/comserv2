-- Internal Links Table
CREATE TABLE IF NOT EXISTS internal_links_tb (
    id INT AUTO_INCREMENT PRIMARY KEY,
    category VARCHAR(50) NOT NULL,
    sitename VARCHAR(50) NOT NULL,
    name VARCHAR(100) NOT NULL,
    url VARCHAR(255) NOT NULL,
    target VARCHAR(20) DEFAULT '_self',
    description TEXT,
    link_order INT DEFAULT 0,
    status INT DEFAULT 1,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Indexes for faster queries
CREATE INDEX IF NOT EXISTS idx_internal_links_category ON internal_links_tb(category);
CREATE INDEX IF NOT EXISTS idx_internal_links_sitename ON internal_links_tb(sitename);
CREATE INDEX IF NOT EXISTS idx_internal_links_status ON internal_links_tb(status);

-- Insert sample data
INSERT INTO internal_links_tb (category, sitename, name, url, target, description, link_order, status)
VALUES 
('Main_links', 'CSC', 'Home', '/', '_self', 'Home page', 1, 2),
('Main_links', 'CSC', 'About', '/about', '_self', 'About page', 2, 2),
('Member_links', 'CSC', 'Dashboard', '/member/dashboard', '_self', 'Member dashboard', 1, 2),
('Admin_links', 'CSC', 'Admin Dashboard', '/admin', '_self', 'Admin dashboard', 1, 2);