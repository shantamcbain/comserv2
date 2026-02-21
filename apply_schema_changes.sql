-- Database Schema Changes for Users Project
-- Phase 1: Create new tables and add columns
-- Run this in MySQL as root or user with ALTER/CREATE privileges

USE ency;

-- Create email_verification_codes table
CREATE TABLE IF NOT EXISTS email_verification_codes (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    code_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    verified_at TIMESTAMP NULL,
    INDEX idx_user_id (user_id),
    INDEX idx_expires_at (expires_at),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Create password_reset_tokens table
CREATE TABLE IF NOT EXISTS password_reset_tokens (
    id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    token_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    used_at TIMESTAMP NULL,
    INDEX idx_user_id (user_id),
    INDEX idx_token_hash (token_hash),
    INDEX idx_expires_at (expires_at),
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Add new columns to users table (check if they exist first to avoid errors)
-- Note: MariaDB/MySQL will error if column already exists, so run these one at a time if needed

-- Add email_notifications column
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_notifications TINYINT(4) NOT NULL DEFAULT 1 AFTER roles;

-- Add status column
ALTER TABLE users ADD COLUMN IF NOT EXISTS status VARCHAR(50) NOT NULL DEFAULT 'active' AFTER email_notifications;

-- Add email_verified_at column
ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMP NULL AFTER status;

-- Add created_by column
ALTER TABLE users ADD COLUMN IF NOT EXISTS created_by INT NULL AFTER email_verified_at;

-- Add creation_context column
ALTER TABLE users ADD COLUMN IF NOT EXISTS creation_context VARCHAR(100) NULL AFTER created_by;

-- Add created_at column
ALTER TABLE users ADD COLUMN IF NOT EXISTS created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER creation_context;

-- Add updated_at column
ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP AFTER created_at;

-- Add foreign key for created_by (self-referencing)
-- Drop first if exists to avoid duplicate key error
ALTER TABLE users DROP FOREIGN KEY IF EXISTS fk_user_created_by;
ALTER TABLE users ADD CONSTRAINT fk_user_created_by FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL;

-- Update existing users to have active status
UPDATE users SET status = 'active' WHERE status IS NULL OR status = '';

-- Verify tables were created
SELECT 'email_verification_codes table:' as info;
SHOW CREATE TABLE email_verification_codes;

SELECT 'password_reset_tokens table:' as info;
SHOW CREATE TABLE password_reset_tokens;

SELECT 'users table structure:' as info;
DESCRIBE users;
