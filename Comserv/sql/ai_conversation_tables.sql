-- AI Conversation Tables Schema
-- Creates ai_conversations and ai_messages tables if they don't exist,
-- and adds project_id / task_id / model columns for planning system integration.

CREATE TABLE IF NOT EXISTS `ai_conversations` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `user_id` INT NOT NULL,
    `title` VARCHAR(255) NULL,
    `project_id` INT NULL,
    `task_id` INT NULL,
    `model` VARCHAR(255) NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `status` ENUM('active', 'archived') NOT NULL DEFAULT 'active',
    PRIMARY KEY (`id`),
    KEY `idx_user_id` (`user_id`),
    KEY `idx_project_id` (`project_id`),
    KEY `idx_task_id` (`task_id`),
    KEY `idx_updated_at` (`updated_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `ai_messages` (
    `id` INT NOT NULL AUTO_INCREMENT,
    `conversation_id` INT NOT NULL,
    `role` ENUM('user', 'assistant') NOT NULL,
    `content` TEXT NOT NULL,
    `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `metadata` JSON NULL,
    PRIMARY KEY (`id`),
    KEY `idx_conversation_id` (`conversation_id`),
    CONSTRAINT `fk_ai_messages_conversation`
        FOREIGN KEY (`conversation_id`) REFERENCES `ai_conversations` (`id`)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Migration: add columns if ai_conversations already exists without them
-- ALTER TABLE `ai_conversations` ADD COLUMN IF NOT EXISTS `project_id` INT NULL;
-- ALTER TABLE `ai_conversations` ADD COLUMN IF NOT EXISTS `task_id` INT NULL;
-- ALTER TABLE `ai_conversations` ADD COLUMN IF NOT EXISTS `model` VARCHAR(255) NULL;
-- ALTER TABLE `ai_conversations` ADD INDEX IF NOT EXISTS `idx_project_id` (`project_id`);
-- ALTER TABLE `ai_conversations` ADD INDEX IF NOT EXISTS `idx_task_id` (`task_id`);
-- ALTER TABLE `ai_conversations` ADD INDEX IF NOT EXISTS `idx_updated_at` (`updated_at`);
