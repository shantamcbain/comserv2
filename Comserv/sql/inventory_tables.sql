-- Inventory System Tables
-- Created for the Comserv Inventory Module
-- Multi-SiteName aware; all tables include sitename column

-- Items / SKUs table
CREATE TABLE IF NOT EXISTS `inventory_items` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `sitename` VARCHAR(255) NOT NULL,
  `sku` VARCHAR(100) NOT NULL,
  `name` VARCHAR(255) NOT NULL,
  `description` TEXT,
  `category` VARCHAR(100),
  `unit_of_measure` VARCHAR(50) NOT NULL DEFAULT 'each',
  `unit_cost` DECIMAL(10,2),
  `reorder_point` INT DEFAULT 0,
  `reorder_quantity` INT DEFAULT 0,
  `status` VARCHAR(50) NOT NULL DEFAULT 'active',
  `notes` TEXT,
  `created_by` VARCHAR(255),
  `created_at` DATETIME,
  `updated_at` DATETIME,
  PRIMARY KEY (`id`),
  UNIQUE KEY `sku_unique` (`sku`),
  KEY `idx_sitename` (`sitename`),
  KEY `idx_status` (`status`),
  KEY `idx_category` (`category`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Suppliers table
CREATE TABLE IF NOT EXISTS `inventory_suppliers` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `sitename` VARCHAR(255) NOT NULL,
  `name` VARCHAR(255) NOT NULL,
  `contact_name` VARCHAR(255),
  `email` VARCHAR(255),
  `phone` VARCHAR(100),
  `address` TEXT,
  `website` VARCHAR(255),
  `lead_time_days` INT DEFAULT 0,
  `status` VARCHAR(50) NOT NULL DEFAULT 'active',
  `notes` TEXT,
  `created_by` VARCHAR(255),
  `created_at` DATETIME,
  `updated_at` DATETIME,
  PRIMARY KEY (`id`),
  KEY `idx_sitename` (`sitename`),
  KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Locations / warehouses / storage areas
CREATE TABLE IF NOT EXISTS `inventory_locations` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `sitename` VARCHAR(255) NOT NULL,
  `name` VARCHAR(255) NOT NULL,
  `description` TEXT,
  `location_type` VARCHAR(100) DEFAULT 'warehouse',
  `address` TEXT,
  `status` VARCHAR(50) NOT NULL DEFAULT 'active',
  `notes` TEXT,
  `created_by` VARCHAR(255),
  `created_at` DATETIME,
  `updated_at` DATETIME,
  PRIMARY KEY (`id`),
  KEY `idx_sitename` (`sitename`),
  KEY `idx_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Stock levels per item per location
CREATE TABLE IF NOT EXISTS `inventory_stock_levels` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `item_id` INT NOT NULL,
  `location_id` INT NOT NULL,
  `quantity_on_hand` DECIMAL(12,3) NOT NULL DEFAULT 0.000,
  `quantity_reserved` DECIMAL(12,3) NOT NULL DEFAULT 0.000,
  `quantity_on_order` DECIMAL(12,3) NOT NULL DEFAULT 0.000,
  `last_count_date` DATETIME,
  `updated_at` DATETIME,
  PRIMARY KEY (`id`),
  UNIQUE KEY `item_location_unique` (`item_id`, `location_id`),
  KEY `idx_item_id` (`item_id`),
  KEY `idx_location_id` (`location_id`),
  CONSTRAINT `fk_stock_item` FOREIGN KEY (`item_id`) REFERENCES `inventory_items` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_stock_location` FOREIGN KEY (`location_id`) REFERENCES `inventory_locations` (`id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Item-Supplier junction table
CREATE TABLE IF NOT EXISTS `inventory_item_suppliers` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `item_id` INT NOT NULL,
  `supplier_id` INT NOT NULL,
  `supplier_sku` VARCHAR(100),
  `unit_cost` DECIMAL(10,2),
  `is_preferred` TINYINT(1) NOT NULL DEFAULT 0,
  `notes` TEXT,
  PRIMARY KEY (`id`),
  UNIQUE KEY `item_supplier_unique` (`item_id`, `supplier_id`),
  KEY `idx_item_id` (`item_id`),
  KEY `idx_supplier_id` (`supplier_id`),
  CONSTRAINT `fk_is_item` FOREIGN KEY (`item_id`) REFERENCES `inventory_items` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_is_supplier` FOREIGN KEY (`supplier_id`) REFERENCES `inventory_suppliers` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Stock transactions / movements
CREATE TABLE IF NOT EXISTS `inventory_transactions` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `item_id` INT NOT NULL,
  `location_id` INT,
  `transaction_type` VARCHAR(50) NOT NULL COMMENT 'receive, issue, adjust, transfer, return',
  `quantity` DECIMAL(12,3) NOT NULL,
  `unit_cost` DECIMAL(10,2),
  `reference_number` VARCHAR(100),
  `todo_id` INT,
  `sitename` VARCHAR(255) NOT NULL,
  `notes` TEXT,
  `performed_by` VARCHAR(255),
  `transaction_date` DATETIME NOT NULL,
  `created_at` DATETIME,
  PRIMARY KEY (`id`),
  KEY `idx_item_id` (`item_id`),
  KEY `idx_location_id` (`location_id`),
  KEY `idx_sitename` (`sitename`),
  KEY `idx_transaction_type` (`transaction_type`),
  KEY `idx_transaction_date` (`transaction_date`),
  KEY `idx_todo_id` (`todo_id`),
  CONSTRAINT `fk_trans_item` FOREIGN KEY (`item_id`) REFERENCES `inventory_items` (`id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_trans_location` FOREIGN KEY (`location_id`) REFERENCES `inventory_locations` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_trans_todo` FOREIGN KEY (`todo_id`) REFERENCES `todo` (`record_id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Item assignments to users/projects/locations
CREATE TABLE IF NOT EXISTS `inventory_assignments` (
  `id` INT NOT NULL AUTO_INCREMENT,
  `item_id` INT NOT NULL,
  `location_id` INT,
  `assigned_to` VARCHAR(255),
  `assigned_to_type` VARCHAR(50) DEFAULT 'user' COMMENT 'user, project, department',
  `quantity` DECIMAL(12,3) NOT NULL DEFAULT 1.000,
  `todo_id` INT,
  `sitename` VARCHAR(255) NOT NULL,
  `status` VARCHAR(50) NOT NULL DEFAULT 'active',
  `notes` TEXT,
  `assigned_by` VARCHAR(255),
  `assigned_at` DATETIME,
  `returned_at` DATETIME,
  `created_at` DATETIME,
  `updated_at` DATETIME,
  PRIMARY KEY (`id`),
  KEY `idx_item_id` (`item_id`),
  KEY `idx_location_id` (`location_id`),
  KEY `idx_sitename` (`sitename`),
  KEY `idx_status` (`status`),
  KEY `idx_assigned_to` (`assigned_to`),
  KEY `idx_todo_id` (`todo_id`),
  CONSTRAINT `fk_assign_item` FOREIGN KEY (`item_id`) REFERENCES `inventory_items` (`id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_assign_location` FOREIGN KEY (`location_id`) REFERENCES `inventory_locations` (`id`) ON DELETE SET NULL,
  CONSTRAINT `fk_assign_todo` FOREIGN KEY (`todo_id`) REFERENCES `todo` (`record_id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
