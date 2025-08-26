-- Chat Messages Table
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    timestamp VARCHAR(255) NOT NULL,
    is_read BOOLEAN NOT NULL DEFAULT 0,
    is_system_message BOOLEAN DEFAULT 0,
    recipient_username VARCHAR(255),
    domain VARCHAR(255),
    site_name VARCHAR(255)
);

-- Index for faster queries
CREATE INDEX IF NOT EXISTS idx_chat_messages_username ON chat_messages(username);
CREATE INDEX IF NOT EXISTS idx_chat_messages_timestamp ON chat_messages(timestamp);
CREATE INDEX IF NOT EXISTS idx_chat_messages_domain ON chat_messages(domain);
CREATE INDEX IF NOT EXISTS idx_chat_messages_site_name ON chat_messages(site_name);