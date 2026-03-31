CREATE TABLE IF NOT EXISTS `access_log` (
  `id`             bigint(20)   NOT NULL AUTO_INCREMENT,
  `timestamp`      datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `sitename`       varchar(100) DEFAULT NULL,
  `path`           varchar(512) NOT NULL,
  `request_method` varchar(10)  DEFAULT NULL,
  `status_code`    smallint(5)  DEFAULT NULL,
  `ip_address`     varchar(45)  DEFAULT NULL,
  `user_agent`     varchar(512) DEFAULT NULL,
  `referer`        varchar(512) DEFAULT NULL,
  `request_type`   varchar(20)  DEFAULT NULL COMMENT 'human|bot|scanner|script|unknown',
  `username`       varchar(255) DEFAULT NULL,
  `session_id`     varchar(128) DEFAULT NULL,
  `system_identifier` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_al_timestamp`    (`timestamp`),
  KEY `idx_al_ip`           (`ip_address`),
  KEY `idx_al_request_type` (`request_type`),
  KEY `idx_al_status_code`  (`status_code`),
  KEY `idx_al_sitename`     (`sitename`),
  KEY `idx_al_path`         (`path`(191))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Request access log — longer retention than system_log. Purge policy: keep 90 days by default.';
