-- Add new columns to users table
-- Run this manually in MySQL

ALTER TABLE users 
    ADD COLUMN email_notifications TINYINT(4) NOT NULL DEFAULT 1 AFTER roles,
    ADD COLUMN status VARCHAR(50) NOT NULL DEFAULT 'active' AFTER email_notifications,
    ADD COLUMN email_verified_at TIMESTAMP NULL AFTER status,
    ADD COLUMN created_by INT NULL AFTER email_verified_at,
    ADD COLUMN creation_context VARCHAR(100) NULL AFTER created_by,
    ADD COLUMN created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER creation_context,
    ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP AFTER created_at;

-- Add foreign key for created_by
ALTER TABLE users
    ADD CONSTRAINT fk_user_created_by FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;
