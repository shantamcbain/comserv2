-- Workshop System Phase 1: Database Schema Extensions
-- Date: 2026-02-15
-- Creates new workshop system tables (workshop table already updated)

-- Create participant table
CREATE TABLE IF NOT EXISTS `participant` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `workshop_id` INTEGER NOT NULL,
  `user_id` INTEGER,
  `name` VARCHAR(255) NOT NULL,
  `email` VARCHAR(255),
  `site_affiliation` VARCHAR(255),
  `registered_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `status` ENUM('registered', 'waitlist', 'attended', 'cancelled') NOT NULL DEFAULT 'registered',
  PRIMARY KEY (`id`),
  INDEX `idx_participant_workshop` (`workshop_id`),
  INDEX `idx_participant_user` (`user_id`),
  INDEX `idx_participant_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create workshop_content table
CREATE TABLE IF NOT EXISTS `workshop_content` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `workshop_id` INTEGER NOT NULL,
  `content_type` ENUM('text', 'powerpoint', 'embedded') NOT NULL DEFAULT 'text',
  `title` VARCHAR(255) NOT NULL,
  `content` TEXT,
  `file_id` INTEGER,
  `sort_order` INTEGER NOT NULL DEFAULT 0,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  INDEX `idx_content_workshop` (`workshop_id`),
  INDEX `idx_content_sort` (`sort_order`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create workshop_emails table
CREATE TABLE IF NOT EXISTS `workshop_emails` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `workshop_id` INTEGER NOT NULL,
  `sent_by` INTEGER NOT NULL,
  `subject` VARCHAR(255) NOT NULL,
  `body` TEXT NOT NULL,
  `sent_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `recipient_count` INTEGER NOT NULL DEFAULT 0,
  `status` ENUM('draft', 'sent', 'failed') NOT NULL DEFAULT 'draft',
  PRIMARY KEY (`id`),
  INDEX `idx_email_workshop` (`workshop_id`),
  INDEX `idx_email_sent_at` (`sent_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create workshop_roles table
CREATE TABLE IF NOT EXISTS `workshop_roles` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `user_id` INTEGER NOT NULL,
  `workshop_id` INTEGER,
  `role` ENUM('workshop_leader') NOT NULL DEFAULT 'workshop_leader',
  `site_id` INTEGER,
  `granted_by` INTEGER,
  `granted_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `user_workshop_role` (`user_id`, `workshop_id`),
  INDEX `idx_role_user` (`user_id`),
  INDEX `idx_role_workshop` (`workshop_id`),
  INDEX `idx_role_site` (`site_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create site_workshop table (junction table for multi-site support)
CREATE TABLE IF NOT EXISTS `site_workshop` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `site_id` INTEGER NOT NULL,
  `workshop_id` INTEGER NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `site_workshop_unique` (`site_id`, `workshop_id`),
  INDEX `idx_site_workshop_site` (`site_id`),
  INDEX `idx_site_workshop_workshop` (`workshop_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
