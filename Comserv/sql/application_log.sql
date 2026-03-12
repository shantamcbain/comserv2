-- application_log table
-- Records health events from all Comserv application instances.
-- Only comserv_server.pl evaluates these records and triggers alerts.
-- Old evaluated records are pruned to keep the table manageable.

CREATE TABLE IF NOT EXISTS `application_log` (
    `id`               INT          NOT NULL AUTO_INCREMENT,
    `app_instance`     VARCHAR(255) NOT NULL DEFAULT 'unknown' COMMENT 'hostname:port (PID:N) of the recording instance',
    `log_level`        VARCHAR(20)  NOT NULL DEFAULT 'INFO'    COMMENT 'DEBUG|INFO|WARN|ERROR|CRITICAL',
    `category`         VARCHAR(50)  NOT NULL DEFAULT 'GENERAL' COMMENT 'FILE_UPLOAD|FILE_DOWNLOAD|EMAIL|DB_ERROR|HTTP_ERROR|AUTH|MEMORY|HEALTH|ERROR|GENERAL',
    `event_type`       VARCHAR(100)     NULL                   COMMENT 'Specific event label within the category',
    `message`          TEXT         NOT NULL                   COMMENT 'Short human-readable event description',
    `details`          TEXT             NULL                   COMMENT 'Full technical details / stack trace',
    `source_file`      VARCHAR(500)     NULL                   COMMENT 'Perl source file (__FILE__)',
    `source_line`      INT              NULL                   COMMENT 'Perl source line (__LINE__)',
    `subroutine`       VARCHAR(255)     NULL                   COMMENT 'Subroutine or method name',
    `hostname`         VARCHAR(255)     NULL                   COMMENT 'System hostname of the container/server',
    `pid`              INT              NULL                   COMMENT 'Process ID of the recording worker',
    `created_at`       DATETIME     NOT NULL DEFAULT NOW()     COMMENT 'Event timestamp (UTC)',
    `evaluated`        TINYINT(1)   NOT NULL DEFAULT 0         COMMENT '1 = processed by health evaluator',
    `evaluation_score` INT              NULL                   COMMENT 'Computed importance score (higher = more critical)',
    `pruned`           TINYINT(1)   NOT NULL DEFAULT 0         COMMENT '1 = safe to delete on next prune cycle',
    `occurrence_count` INT          NOT NULL DEFAULT 1         COMMENT 'Collapsed repetition counter',
    PRIMARY KEY (`id`),
    INDEX `idx_app_log_created`   (`created_at`),
    INDEX `idx_app_log_evaluated` (`evaluated`, `pruned`),
    INDEX `idx_app_log_level`     (`log_level`),
    INDEX `idx_app_log_category`  (`category`),
    INDEX `idx_app_log_instance`  (`app_instance`(64))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
  COMMENT='Comserv server health event log - evaluated by comserv_server.pl';
