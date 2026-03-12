CREATE TABLE IF NOT EXISTS `system_log` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `timestamp` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `level` varchar(20) NOT NULL DEFAULT 'info',
  `file` varchar(255) DEFAULT NULL,
  `line` int(11) DEFAULT NULL,
  `subroutine` varchar(255) DEFAULT NULL,
  `message` text DEFAULT NULL,
  `sitename` varchar(255) DEFAULT NULL,
  `username` varchar(255) DEFAULT NULL,
  `system_identifier` varchar(255) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_timestamp` (`timestamp`),
  KEY `idx_level` (`level`),
  KEY `idx_sitename` (`sitename`),
  KEY `idx_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
