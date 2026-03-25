CREATE TABLE IF NOT EXISTS `user_api_keys` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `site_id` int(11) DEFAULT NULL,
  `service` enum('grok','openai','claude','gemini','anthropic','cohere') NOT NULL,
  `api_key_encrypted` text NOT NULL,
  `metadata` text DEFAULT NULL,
  `is_active` tinyint(1) NOT NULL DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_user_site_service` (`user_id`,`site_id`,`service`),
  KEY `idx_user_id` (`user_id`),
  KEY `idx_service` (`service`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
