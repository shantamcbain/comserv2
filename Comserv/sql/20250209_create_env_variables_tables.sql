-- Comserv Environment Variables Management System
-- Created: 2025-12-09
-- Purpose: Create tables for environment variable management with auditing

-- Create env_variables table
CREATE TABLE IF NOT EXISTS env_variables (
    id INT AUTO_INCREMENT PRIMARY KEY,
    `key` VARCHAR(255) NOT NULL UNIQUE,
    `value` LONGTEXT,
    var_type VARCHAR(50) NOT NULL DEFAULT 'string',
    is_secret BOOLEAN NOT NULL DEFAULT 0,
    is_editable BOOLEAN NOT NULL DEFAULT 1,
    editable_by_roles JSON NOT NULL DEFAULT '["admin"]',
    affected_services JSON,
    description TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    created_by INT,
    updated_by INT,
    
    INDEX idx_key (`key`),
    INDEX idx_created_at (created_at),
    INDEX idx_is_secret (is_secret),
    INDEX idx_var_type (var_type),
    
    FOREIGN KEY (created_by) REFERENCES users(id) ON DELETE SET NULL,
    FOREIGN KEY (updated_by) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Environment variables with type information and audit capabilities';

-- Create env_variable_audit_logs table
CREATE TABLE IF NOT EXISTS env_variable_audit_logs (
    id INT AUTO_INCREMENT PRIMARY KEY,
    env_variable_id INT NOT NULL,
    user_id INT,
    `action` VARCHAR(50) NOT NULL,
    old_value LONGTEXT,
    new_value LONGTEXT,
    `status` VARCHAR(50) NOT NULL DEFAULT 'pending',
    ip_address VARCHAR(45),
    affected_services JSON,
    error_message TEXT,
    docker_restart_output LONGTEXT,
    rollback_details JSON,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_env_variable_id (env_variable_id),
    INDEX idx_user_id (user_id),
    INDEX idx_action (`action`),
    INDEX idx_status (`status`),
    INDEX idx_created_at (created_at),
    
    FOREIGN KEY (env_variable_id) REFERENCES env_variables(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
COMMENT='Audit log for all environment variable changes with masking support';

-- Create indexes for performance
CREATE INDEX idx_env_var_secret_editable ON env_variables(is_secret, is_editable);
CREATE INDEX idx_audit_log_time_range ON env_variable_audit_logs(created_at, env_variable_id);
