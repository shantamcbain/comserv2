-- Migration: Workshop System - Extend Tables and Add New Tables
-- Date: 2026-02-14
-- Phase: 1A - Database Schema Migration
-- Description: Extends workshop and participant tables, creates workshop_content,
--              workshop_emails, workshop_roles, and site_workshop tables

-- ============================================================================
-- PART 1: ALTER EXISTING TABLES
-- ============================================================================

-- Extend workshop table with lifecycle management, timestamps, and site support
ALTER TABLE `workshop` 
  ADD COLUMN `status` ENUM('draft', 'published', 'registration_closed', 'in_progress', 'completed', 'cancelled') 
    NOT NULL DEFAULT 'draft' AFTER `max_participants`,
  ADD COLUMN `created_by` INTEGER AFTER `status`,
  ADD COLUMN `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER `created_by`,
  ADD COLUMN `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP AFTER `created_at`,
  ADD COLUMN `registration_deadline` DATETIME AFTER `updated_at`,
  ADD COLUMN `site_id` INTEGER AFTER `registration_deadline`,
  ADD INDEX `idx_workshop_status` (`status`),
  ADD INDEX `idx_workshop_created_by` (`created_by`),
  ADD INDEX `idx_workshop_site` (`site_id`),
  ADD INDEX `idx_workshop_date` (`date`);

-- Extend participant table with user tracking, email, and status management
ALTER TABLE `participant`
  ADD COLUMN `user_id` INTEGER AFTER `workshop_id`,
  ADD COLUMN `email` VARCHAR(255) AFTER `name`,
  ADD COLUMN `site_affiliation` VARCHAR(255) AFTER `email`,
  ADD COLUMN `registered_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER `site_affiliation`,
  ADD COLUMN `status` ENUM('registered', 'waitlist', 'attended', 'cancelled') 
    NOT NULL DEFAULT 'registered' AFTER `registered_at`,
  ADD INDEX `idx_participant_workshop` (`workshop_id`),
  ADD INDEX `idx_participant_user` (`user_id`),
  ADD INDEX `idx_participant_status` (`status`);

-- ============================================================================
-- PART 2: CREATE NEW TABLES
-- ============================================================================

-- Create workshop_content table for online materials (text, powerpoint, embedded)
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
  FOREIGN KEY (`workshop_id`) REFERENCES `workshop` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`file_id`) REFERENCES `files` (`id`) ON DELETE SET NULL,
  INDEX `idx_content_workshop` (`workshop_id`),
  INDEX `idx_content_sort` (`sort_order`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create workshop_emails table for email history and tracking
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
  FOREIGN KEY (`workshop_id`) REFERENCES `workshop` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`sent_by`) REFERENCES `users` (`id`) ON DELETE SET NULL,
  INDEX `idx_email_workshop` (`workshop_id`),
  INDEX `idx_email_sent_at` (`sent_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create workshop_roles table for granular role assignment (workshop leaders)
CREATE TABLE IF NOT EXISTS `workshop_roles` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `user_id` INTEGER NOT NULL,
  `workshop_id` INTEGER,
  `role` ENUM('workshop_leader') NOT NULL DEFAULT 'workshop_leader',
  `site_id` INTEGER,
  `granted_by` INTEGER,
  `granted_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`workshop_id`) REFERENCES `workshop` (`id`) ON DELETE CASCADE,
  FOREIGN KEY (`granted_by`) REFERENCES `users` (`id`) ON DELETE SET NULL,
  UNIQUE KEY `user_workshop_role` (`user_id`, `workshop_id`),
  INDEX `idx_role_user` (`user_id`),
  INDEX `idx_role_workshop` (`workshop_id`),
  INDEX `idx_role_site` (`site_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Create site_workshop junction table for multi-site workshop support
CREATE TABLE IF NOT EXISTS `site_workshop` (
  `id` INTEGER NOT NULL AUTO_INCREMENT,
  `site_id` INTEGER NOT NULL,
  `workshop_id` INTEGER NOT NULL,
  `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  FOREIGN KEY (`workshop_id`) REFERENCES `workshop` (`id`) ON DELETE CASCADE,
  UNIQUE KEY `site_workshop_unique` (`site_id`, `workshop_id`),
  INDEX `idx_site_workshop_site` (`site_id`),
  INDEX `idx_site_workshop_workshop` (`workshop_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- MIGRATION COMPLETE
-- ============================================================================
-- Tables modified: workshop, participant
-- Tables created: workshop_content, workshop_emails, workshop_roles, site_workshop
-- Next step: Update DBIx::Class Result classes (Phase 1B)
