-- Support Tickets table for HelpDesk system
-- Run this migration on the ency database

CREATE TABLE IF NOT EXISTS support_tickets (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    ticket_number   VARCHAR(50) NOT NULL UNIQUE,
    site_name       VARCHAR(255),
    user_id         INT,
    username        VARCHAR(255),
    email           VARCHAR(255),
    subject         VARCHAR(500) NOT NULL,
    description     TEXT NOT NULL,
    category        VARCHAR(100) DEFAULT 'other',
    priority        VARCHAR(50)  DEFAULT 'medium',
    status          VARCHAR(50)  NOT NULL DEFAULT 'open',
    assigned_to     VARCHAR(255),
    resolution      TEXT,
    created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME ON UPDATE CURRENT_TIMESTAMP,
    closed_at       DATETIME,
    conversation_id INT,
    metadata        TEXT,
    INDEX idx_site_name   (site_name),
    INDEX idx_user_id     (user_id),
    INDEX idx_status      (status),
    INDEX idx_created_at  (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
