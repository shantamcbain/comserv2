CREATE TABLE IF NOT EXISTS internal_links_tb (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  category VARCHAR(50) NOT NULL,
  sitename VARCHAR(50) NOT NULL,
  name VARCHAR(100) NOT NULL,
  url VARCHAR(255) NOT NULL,
  target VARCHAR(20) DEFAULT '_self',
  description TEXT,
  link_order INTEGER DEFAULT 0,
  status INTEGER DEFAULT 1,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
-- Note: description holds owner username for private links (Phase 1).
-- Cross-site toggle uses sitename='All'.
