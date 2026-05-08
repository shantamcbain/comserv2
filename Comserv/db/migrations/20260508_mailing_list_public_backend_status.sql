-- Migration: Add public/private, backend type, subscription status, block, and unsubscribe token
-- Date: 2026-05-08
-- Apply to: ency database

-- mailing_lists: public flag + backend provider + backend config JSON
ALTER TABLE `mailing_lists`
    ADD COLUMN IF NOT EXISTS `is_public`      TINYINT NOT NULL DEFAULT 0 AFTER `is_active`,
    ADD COLUMN IF NOT EXISTS `list_backend`   VARCHAR(50) NOT NULL DEFAULT 'local' AFTER `is_public`,
    ADD COLUMN IF NOT EXISTS `backend_config` TEXT NULL AFTER `list_backend`;

-- list_backend values: local | mailchimp | mailserver | virtualmin

-- mailing_list_subscriptions: status, block info, one-click unsubscribe token
ALTER TABLE `mailing_list_subscriptions`
    ADD COLUMN IF NOT EXISTS `status`           VARCHAR(20) NOT NULL DEFAULT 'subscribed' AFTER `is_active`,
    ADD COLUMN IF NOT EXISTS `unsubscribed_at`  TIMESTAMP NULL AFTER `status`,
    ADD COLUMN IF NOT EXISTS `blocked_by`       INT NULL AFTER `unsubscribed_at`,
    ADD COLUMN IF NOT EXISTS `blocked_at`       TIMESTAMP NULL AFTER `blocked_by`,
    ADD COLUMN IF NOT EXISTS `blocked_reason`   TEXT NULL AFTER `blocked_at`,
    ADD COLUMN IF NOT EXISTS `unsubscribe_token` VARCHAR(64) NULL AFTER `blocked_reason`;

-- status values: subscribed | unsubscribed | blocked

ALTER TABLE `mailing_list_subscriptions`
    ADD INDEX IF NOT EXISTS `idx_status`            (`status`),
    ADD INDEX IF NOT EXISTS `idx_unsubscribe_token` (`unsubscribe_token`);
