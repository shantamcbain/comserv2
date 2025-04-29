-- Page Table
CREATE TABLE IF NOT EXISTS page_tb (
    id INT AUTO_INCREMENT PRIMARY KEY,
    menu VARCHAR(50) NOT NULL,
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
CREATE INDEX IF NOT EXISTS idx_page_menu ON page_tb(menu);
CREATE INDEX IF NOT EXISTS idx_page_sitename ON page_tb(sitename);
CREATE INDEX IF NOT EXISTS idx_page_status ON page_tb(status);

-- Insert sample data
INSERT INTO page_tb (menu, sitename, name, url, target, description, link_order, status)
VALUES 
('Main', 'CSC', 'Home', '/', '_self', 'Home page', 1, 2),
('Main', 'CSC', 'Services', '/services', '_self', 'Services page', 2, 2),
('member', 'CSC', 'Dashboard', '/member/dashboard', '_self', 'Member dashboard', 1, 2),
('Admin', 'CSC', 'Dashboard', '/admin', '_self', 'Admin dashboard', 1, 2);