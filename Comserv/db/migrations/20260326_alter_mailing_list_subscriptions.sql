-- Migration: Alter mailing_list_subscriptions to support email-only subscribers
-- Date: 2026-03-26
-- Apply to: ency database
-- Purpose: Workshop attendees registered without a system account need email-only subscription rows.
-- Run this if mailing_list_subscriptions table already exists.

ALTER TABLE `mailing_list_subscriptions`
    MODIFY COLUMN `user_id` INT NULL;

ALTER TABLE `mailing_list_subscriptions`
    ADD COLUMN IF NOT EXISTS `email` VARCHAR(255) NULL AFTER `user_id`;

ALTER TABLE `mailing_list_subscriptions`
    ADD COLUMN IF NOT EXISTS `display_name` VARCHAR(255) NULL AFTER `email`;

ALTER TABLE `mailing_list_subscriptions`
    ADD INDEX IF NOT EXISTS `idx_email` (`email`);

-- Remove old unique key that required non-null user_id
-- (ignore error if it doesn't exist)
ALTER TABLE `mailing_list_subscriptions`
    DROP INDEX IF EXISTS `unique_subscription`;
