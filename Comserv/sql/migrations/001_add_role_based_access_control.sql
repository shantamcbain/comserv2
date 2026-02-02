-- Migration: Add Role-Based Access Control and Audit Trail
-- Date: 2026-02-02
-- Phase: 1 - Database Schema & Models

-- Create site_roles table
CREATE TABLE IF NOT EXISTS `site_roles` (
    `id` INTEGER NOT NULL AUTO_INCREMENT,
    `sitename` VARCHAR(255) NOT NULL,
    `role_name` VARCHAR(100) NOT NULL,
    `description` TEXT,
    `is_system_role` BOOLEAN NOT NULL DEFAULT 0,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `sitename_role_unique` (`sitename`, `role_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create user_site_roles table
CREATE TABLE IF NOT EXISTS `user_site_roles` (
    `id` INTEGER NOT NULL AUTO_INCREMENT,
    `user_id` INTEGER NOT NULL,
    `role_id` INTEGER NOT NULL,
    `sitename` VARCHAR(255) NOT NULL,
    `assigned_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `assigned_by` INTEGER,
    PRIMARY KEY (`id`),
    UNIQUE KEY `user_role_site_unique` (`user_id`, `role_id`, `sitename`),
    FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
    FOREIGN KEY (`role_id`) REFERENCES `site_roles` (`id`) ON DELETE CASCADE,
    FOREIGN KEY (`assigned_by`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create plan_audit table
CREATE TABLE IF NOT EXISTS `plan_audit` (
    `id` INTEGER NOT NULL AUTO_INCREMENT,
    `entity_type` VARCHAR(50) NOT NULL,
    `entity_id` INTEGER NOT NULL,
    `action` VARCHAR(50) NOT NULL,
    `user_id` INTEGER,
    `username` VARCHAR(255),
    `changed_fields` JSON,
    `ip_address` VARCHAR(45),
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `entity_lookup` (`entity_type`, `entity_id`),
    KEY `created_at_idx` (`created_at`),
    FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Add allowed_roles column to dailyplan table
ALTER TABLE `dailyplan` ADD COLUMN `allowed_roles` JSON AFTER `last_modified`;

-- Add allowed_roles column to todo table
ALTER TABLE `todo` ADD COLUMN `allowed_roles` JSON AFTER `scheduled_date`;

-- Create indexes for performance
CREATE INDEX `idx_site_roles_sitename` ON `site_roles` (`sitename`);
CREATE INDEX `idx_user_site_roles_user` ON `user_site_roles` (`user_id`);
CREATE INDEX `idx_user_site_roles_sitename` ON `user_site_roles` (`sitename`);
CREATE INDEX `idx_plan_audit_user` ON `plan_audit` (`user_id`);
