-- Module Access Control System
-- Creates site_modules and user_module_access tables
-- Apply to: ency database on 192.168.1.198

CREATE TABLE IF NOT EXISTS `site_modules` (
    `id`          INT NOT NULL AUTO_INCREMENT,
    `sitename`    VARCHAR(100) NOT NULL,
    `module_name` VARCHAR(100) NOT NULL,
    `enabled`     TINYINT(1) NOT NULL DEFAULT 1,
    `min_role`    VARCHAR(50)  NOT NULL DEFAULT 'member',
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `site_module_unique` (`sitename`, `module_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `user_module_access` (
    `id`          INT NOT NULL AUTO_INCREMENT,
    `username`    VARCHAR(255) NOT NULL,
    `sitename`    VARCHAR(100) NOT NULL,
    `module_name` VARCHAR(100) NOT NULL,
    `granted`     TINYINT(1) NOT NULL DEFAULT 1,
    `granted_by`  VARCHAR(255) DEFAULT NULL,
    `created_at`  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `user_module_unique` (`username`, `sitename`, `module_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Seed: enable 'planning' module for all known active SiteNames (min role: member)
INSERT IGNORE INTO `site_modules` (`sitename`, `module_name`, `enabled`, `min_role`) VALUES
    ('CSC',      'planning', 1, 'member'),
    ('BMaster',  'planning', 1, 'member'),
    ('Shanta',   'planning', 1, 'member'),
    ('Monashee', 'planning', 1, 'member'),
    ('Forager',  'planning', 1, 'member'),
    ('USBL',     'planning', 1, 'member');
