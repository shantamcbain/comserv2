CREATE TABLE IF NOT EXISTS `hardware_metrics` (
  `id`               bigint(20)    NOT NULL AUTO_INCREMENT,
  `timestamp`        datetime      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `system_identifier` varchar(255) NOT NULL,
  `hostname`         varchar(255)  NOT NULL,
  `metric_name`      varchar(100)  NOT NULL,
  `metric_value`     decimal(12,3) DEFAULT NULL,
  `metric_text`      varchar(255)  DEFAULT NULL,
  `unit`             varchar(20)   DEFAULT NULL,
  `level`            varchar(20)   NOT NULL DEFAULT 'info'
                       COMMENT 'debug|info|warn|error|critical — same as system_log',
  `message`          text          DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_hm_timestamp`  (`timestamp`),
  KEY `idx_hm_system`     (`system_identifier`),
  KEY `idx_hm_metric`     (`metric_name`),
  KEY `idx_hm_level`      (`level`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Hardware/system metrics collected by hardware_monitor.pl. Retention: 90 days.';
