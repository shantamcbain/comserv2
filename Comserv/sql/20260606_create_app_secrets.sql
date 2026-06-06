CREATE TABLE IF NOT EXISTS `app_secrets` (
  `id`           INT NOT NULL AUTO_INCREMENT,
  `secret_key`   VARCHAR(100) NOT NULL,
  `secret_value` TEXT NOT NULL,
  `description`  VARCHAR(255) DEFAULT NULL,
  `updated_at`   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `updated_by`   VARCHAR(100) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `app_secrets_secret_key` (`secret_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
