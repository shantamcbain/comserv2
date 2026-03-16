ALTER TABLE `system_log`
    ADD COLUMN IF NOT EXISTS `ip_address`      varchar(45)  DEFAULT NULL AFTER `username`,
    ADD COLUMN IF NOT EXISTS `user_agent`       varchar(512) DEFAULT NULL AFTER `ip_address`,
    ADD COLUMN IF NOT EXISTS `referer`          varchar(512) DEFAULT NULL AFTER `user_agent`,
    ADD COLUMN IF NOT EXISTS `request_method`   varchar(10)  DEFAULT NULL AFTER `referer`,
    ADD COLUMN IF NOT EXISTS `request_type`     varchar(20)  DEFAULT NULL AFTER `request_method`,
    ADD KEY IF NOT EXISTS `idx_ip_address`     (`ip_address`),
    ADD KEY IF NOT EXISTS `idx_request_type`   (`request_type`);
