-- Migration: Create mailing lists tables for unified mail system
-- Date: 2026-03-26
-- Apply to: ency database

CREATE TABLE IF NOT EXISTS `mailing_lists` (
    `id`                INT NOT NULL AUTO_INCREMENT,
    `site_id`           INT NOT NULL,
    `name`              VARCHAR(255) NOT NULL,
    `description`       TEXT,
    `list_email`        VARCHAR(255),
    `virtualmin_list_id` VARCHAR(255),
    `is_software_only`  TINYINT NOT NULL DEFAULT 1,
    `is_active`         TINYINT NOT NULL DEFAULT 1,
    `created_by`        INT NOT NULL DEFAULT 0,
    `created_at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `unique_site_name` (`site_id`, `name`),
    INDEX `idx_site_id` (`site_id`),
    INDEX `idx_is_active` (`is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `mailing_list_subscriptions` (
    `id`                    INT NOT NULL AUTO_INCREMENT,
    `mailing_list_id`       INT NOT NULL,
    `user_id`               INT NULL,
    `email`                 VARCHAR(255) NULL,
    `display_name`          VARCHAR(255) NULL,
    `subscription_source`   VARCHAR(50),
    `source_id`             INT,
    `subscribed_at`         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `is_active`             TINYINT NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    INDEX `idx_list_active` (`mailing_list_id`, `is_active`),
    INDEX `idx_user_id` (`user_id`),
    INDEX `idx_email` (`email`),
    FOREIGN KEY (`mailing_list_id`) REFERENCES `mailing_lists` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ALTER for existing installs (safe to re-run, errors ignored by application)
-- Run these manually if the table already exists:
-- ALTER TABLE `mailing_list_subscriptions` MODIFY COLUMN `user_id` INT NULL;
-- ALTER TABLE `mailing_list_subscriptions` ADD COLUMN IF NOT EXISTS `email` VARCHAR(255) NULL AFTER `user_id`;
-- ALTER TABLE `mailing_list_subscriptions` ADD COLUMN IF NOT EXISTS `display_name` VARCHAR(255) NULL AFTER `email`;
-- DROP INDEX IF EXISTS `unique_subscription` ON `mailing_list_subscriptions`;

CREATE TABLE IF NOT EXISTS `mailing_list_campaigns` (
    `id`                INT NOT NULL AUTO_INCREMENT,
    `mailing_list_id`   INT NOT NULL,
    `subject`           VARCHAR(500) NOT NULL,
    `body`              MEDIUMTEXT,
    `sent_by`           INT NOT NULL DEFAULT 0,
    `sent_at`           TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `recipient_count`   INT NOT NULL DEFAULT 0,
    `success_count`     INT NOT NULL DEFAULT 0,
    `fail_count`        INT NOT NULL DEFAULT 0,
    PRIMARY KEY (`id`),
    INDEX `idx_list_id` (`mailing_list_id`),
    FOREIGN KEY (`mailing_list_id`) REFERENCES `mailing_lists` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
