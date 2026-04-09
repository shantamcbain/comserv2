-- Beekeeping Equipment Bill of Materials (BOM) Schema
-- Adds component-part tracking for frames, boxes, and hive accessories
-- Run AFTER apiary_schema.sql

SET FOREIGN_KEY_CHECKS = 1;

-- ============================================================================
-- EQUIPMENT TYPE CATALOGUE
-- Defines each type of assembled component (frame, box, bottom board, etc.)
-- ============================================================================

CREATE TABLE IF NOT EXISTS `bee_equipment_types` (
  `id`               INT NOT NULL AUTO_INCREMENT,
  `name`             VARCHAR(100) NOT NULL,
  `category`         ENUM('frame','box','bottom_board','inner_cover','outer_cover','feeder','queen_excluder','nuc','other') NOT NULL DEFAULT 'other',
  `description`      TEXT,
  `frame_count`      INT DEFAULT 0 COMMENT 'Standard frame capacity (for box types)',
  `box_size`         ENUM('deep','medium','shallow','5_frame','nuc','none') DEFAULT 'none',
  `is_active`        TINYINT(1) NOT NULL DEFAULT 1,
  `notes`            TEXT,
  `created_by`       VARCHAR(50),
  `created_at`       TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `updated_at`       TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_name_category` (`name`, `category`),
  KEY `idx_category` (`category`),
  KEY `idx_is_active` (`is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- BILL OF MATERIALS
-- Each row = one part/material needed to build one unit of an equipment type
-- ============================================================================

CREATE TABLE IF NOT EXISTS `bee_equipment_bom` (
  `id`                INT NOT NULL AUTO_INCREMENT,
  `equipment_type_id` INT NOT NULL,
  `part_name`         VARCHAR(150) NOT NULL,
  `quantity`          DECIMAL(10,3) NOT NULL DEFAULT 1.000,
  `unit`              VARCHAR(30) NOT NULL DEFAULT 'each'
                      COMMENT 'each, gram, ml, litre, cm, sheet',
  `is_optional`       TINYINT(1) NOT NULL DEFAULT 0,
  `material`          VARCHAR(100)
                      COMMENT 'pine, galvanized, beeswax, plastic, etc.',
  `inventory_item_id` INT DEFAULT NULL
                      COMMENT 'FK to inventory_items for stock / procurement',
  `sort_order`        INT DEFAULT 0,
  `notes`             TEXT,
  `created_at`        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `updated_at`        TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_type_part` (`equipment_type_id`, `part_name`),
  KEY `idx_equipment_type_id` (`equipment_type_id`),
  KEY `idx_inventory_item_id` (`inventory_item_id`),
  CONSTRAINT `fk_bom_type`
    FOREIGN KEY (`equipment_type_id`) REFERENCES `bee_equipment_types` (`id`)
    ON DELETE CASCADE,
  CONSTRAINT `fk_bom_inventory`
    FOREIGN KEY (`inventory_item_id`) REFERENCES `inventory_items` (`id`)
    ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- HIVE COMPONENT INSTANCES
-- Physical units of bottom boards, inner covers, outer covers/tops, feeders,
-- queen excluders — each attached to a hive, with condition and BOM type
-- ============================================================================

CREATE TABLE IF NOT EXISTS `hive_components` (
  `id`                INT NOT NULL AUTO_INCREMENT,
  `hive_id`           INT DEFAULT NULL
                      COMMENT 'Hive currently using this component (NULL = stored)',
  `equipment_type_id` INT NOT NULL,
  `serial_number`     VARCHAR(100),
  `condition`         ENUM('new','good','fair','poor','damaged') NOT NULL DEFAULT 'new',
  `status`            ENUM('in_use','stored','needs_repair','retired') NOT NULL DEFAULT 'in_use',
  `assembled_date`    DATE,
  `assembled_by`      VARCHAR(100),
  `purchase_date`     DATE,
  `cost`              DECIMAL(8,2),
  `sitename`          VARCHAR(50),
  `notes`             TEXT,
  `created_by`        VARCHAR(50),
  `created_at`        TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `updated_at`        TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_hive_id` (`hive_id`),
  KEY `idx_equipment_type_id` (`equipment_type_id`),
  KEY `idx_status` (`status`),
  KEY `idx_condition` (`condition`),
  KEY `idx_sitename` (`sitename`),
  CONSTRAINT `fk_hc_hive`
    FOREIGN KEY (`hive_id`) REFERENCES `hives` (`id`)
    ON DELETE SET NULL,
  CONSTRAINT `fk_hc_type`
    FOREIGN KEY (`equipment_type_id`) REFERENCES `bee_equipment_types` (`id`)
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- ALTER EXISTING TABLES: add equipment_type_id FK
-- ============================================================================

ALTER TABLE `boxes`
  ADD COLUMN IF NOT EXISTS `equipment_type_id` INT DEFAULT NULL
    COMMENT 'FK to bee_equipment_types — defines BOM for this box',
  ADD KEY IF NOT EXISTS `idx_boxes_equipment_type_id` (`equipment_type_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_box_equipment_type`
    FOREIGN KEY (`equipment_type_id`) REFERENCES `bee_equipment_types` (`id`)
    ON DELETE SET NULL;

ALTER TABLE `hive_frames`
  ADD COLUMN IF NOT EXISTS `equipment_type_id` INT DEFAULT NULL
    COMMENT 'FK to bee_equipment_types — defines BOM for this frame',
  ADD COLUMN IF NOT EXISTS `has_foundation` TINYINT(1) NOT NULL DEFAULT 0
    COMMENT 'Whether foundation is installed',
  ADD KEY IF NOT EXISTS `idx_frames_equipment_type_id` (`equipment_type_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_frame_equipment_type`
    FOREIGN KEY (`equipment_type_id`) REFERENCES `bee_equipment_types` (`id`)
    ON DELETE SET NULL;

-- ============================================================================
-- SEED DATA: Standard beekeeping equipment types and their BOMs
-- ============================================================================

-- Equipment Types
INSERT IGNORE INTO `bee_equipment_types` (`name`, `category`, `description`, `frame_count`, `box_size`) VALUES
  ('Standard Deep Frame',        'frame',         'Full-depth Langstroth frame (9-1/8" deep)', 0,  'deep'),
  ('Standard Medium Frame',      'frame',         'Medium Langstroth frame (6-1/4" deep)',       0,  'medium'),
  ('Standard Shallow Frame',     'frame',         'Shallow Langstroth frame (5-3/8" deep)',      0,  'shallow'),
  ('Deep Box (10-frame)',        'box',           '10-frame deep Langstroth box',                10, 'deep'),
  ('Medium Box (10-frame)',      'box',           '10-frame medium super',                       10, 'medium'),
  ('Shallow Box (10-frame)',     'box',           '10-frame shallow super',                      10, 'shallow'),
  ('Deep Box (8-frame)',         'box',           '8-frame deep Langstroth box',                 8,  'deep'),
  ('Medium Box (8-frame)',       'box',           '8-frame medium super',                        8,  'medium'),
  ('5-Frame Nuc Box',            'nuc',           '5-frame nucleus hive',                        5,  '5_frame'),
  ('Screened Bottom Board',      'bottom_board',  'Ventilated bottom board with varroa drawer',  0,  'none'),
  ('Solid Bottom Board',         'bottom_board',  'Traditional solid bottom board',              0,  'none'),
  ('Standard Inner Cover',       'inner_cover',   'Wood inner cover with notch',                 0,  'none'),
  ('Ventilated Inner Cover',     'inner_cover',   'Screened inner cover for summer ventilation', 0,  'none'),
  ('Telescoping Outer Cover',    'outer_cover',   'Metal-clad telescoping top cover',            0,  'none'),
  ('Migratory Outer Cover',      'outer_cover',   'Flat migratory cover (no overhang)',          0,  'none'),
  ('Top Hive Feeder',            'feeder',        'Frame-style feeder sitting on top bars',      0,  'none'),
  ('Boardman Entrance Feeder',   'feeder',        'Inverted jar feeder at hive entrance',        0,  'none'),
  ('Hive-Top Pail Feeder',       'feeder',        'Inverted pail feeder under cover',            0,  'none'),
  ('Wire Queen Excluder',        'queen_excluder','Wire zinc queen excluder',                    0,  'none'),
  ('Plastic Queen Excluder',     'queen_excluder','Plastic slot queen excluder',                 0,  'none');

-- BOM: Standard Deep Frame
INSERT IGNORE INTO `bee_equipment_bom` (`equipment_type_id`, `part_name`, `quantity`, `unit`, `is_optional`, `material`, `sort_order`) VALUES
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Deep Frame'), 'Top Bar',        1,  'each', 0, 'pine',        1),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Deep Frame'), 'Bottom Bar',     1,  'each', 0, 'pine',        2),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Deep Frame'), 'End Bar',        2,  'each', 0, 'pine',        3),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Deep Frame'), 'Nail 1.5 inch',  24, 'each', 0, 'galvanized',  4),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Deep Frame'), 'Foundation',     1,  'each', 1, 'beeswax',     5);

-- BOM: Standard Medium Frame
INSERT IGNORE INTO `bee_equipment_bom` (`equipment_type_id`, `part_name`, `quantity`, `unit`, `is_optional`, `material`, `sort_order`) VALUES
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Medium Frame'), 'Top Bar',        1,  'each', 0, 'pine',       1),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Medium Frame'), 'Bottom Bar',     1,  'each', 0, 'pine',       2),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Medium Frame'), 'End Bar',        2,  'each', 0, 'pine',       3),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Medium Frame'), 'Nail 1.5 inch',  20, 'each', 0, 'galvanized', 4),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Medium Frame'), 'Foundation',     1,  'each', 1, 'beeswax',    5);

-- BOM: Deep Box (10-frame)
INSERT IGNORE INTO `bee_equipment_bom` (`equipment_type_id`, `part_name`, `quantity`, `unit`, `is_optional`, `material`, `sort_order`) VALUES
  ((SELECT id FROM bee_equipment_types WHERE name='Deep Box (10-frame)'), 'Side Panel',    2,    'each',  0, 'pine',       1),
  ((SELECT id FROM bee_equipment_types WHERE name='Deep Box (10-frame)'), 'End Panel',     2,    'each',  0, 'pine',       2),
  ((SELECT id FROM bee_equipment_types WHERE name='Deep Box (10-frame)'), 'Nail 2 inch',   40,   'each',  0, 'galvanized', 3),
  ((SELECT id FROM bee_equipment_types WHERE name='Deep Box (10-frame)'), 'Paint/Finish',  0.25, 'litre', 1, 'exterior',   4);

-- BOM: Screened Bottom Board
INSERT IGNORE INTO `bee_equipment_bom` (`equipment_type_id`, `part_name`, `quantity`, `unit`, `is_optional`, `material`, `sort_order`) VALUES
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Frame Board Side', 2,  'each',  0, 'pine',      1),
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Frame Board End',  2,  'each',  0, 'pine',      2),
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Wire Mesh Screen',  1,  'each',  0, '#8 mesh',   3),
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Varroa Drawer',    1,  'each',  0, 'coroplast', 4),
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Entrance Reducer',  1,  'each',  1, 'pine',      5),
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Nail 2 inch',      20, 'each',  0, 'galvanized',6),
  ((SELECT id FROM bee_equipment_types WHERE name='Screened Bottom Board'), 'Staple',           16, 'each',  0, 'galvanized',7);

-- BOM: Standard Inner Cover
INSERT IGNORE INTO `bee_equipment_bom` (`equipment_type_id`, `part_name`, `quantity`, `unit`, `is_optional`, `material`, `sort_order`) VALUES
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Inner Cover'), 'Top Panel',   1,  'each', 0, 'plywood 1/4"', 1),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Inner Cover'), 'Rim Side',    2,  'each', 0, 'pine',         2),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Inner Cover'), 'Rim End',     2,  'each', 0, 'pine',         3),
  ((SELECT id FROM bee_equipment_types WHERE name='Standard Inner Cover'), 'Nail 1 inch', 16, 'each', 0, 'galvanized',   4);

-- BOM: Telescoping Outer Cover
INSERT IGNORE INTO `bee_equipment_bom` (`equipment_type_id`, `part_name`, `quantity`, `unit`, `is_optional`, `material`, `sort_order`) VALUES
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Top Panel',     1,    'each',  0, 'plywood 3/8"', 1),
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Metal Flashing', 1,   'each',  0, 'galvanized',   2),
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Rim Side',       2,   'each',  0, 'pine',         3),
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Rim End',        2,   'each',  0, 'pine',         4),
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Nail 1.5 inch',  24,  'each',  0, 'galvanized',   5),
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Staple',         12,  'each',  0, 'galvanized',   6),
  ((SELECT id FROM bee_equipment_types WHERE name='Telescoping Outer Cover'), 'Paint/Finish',   0.1, 'litre', 1, 'exterior',     7);

COMMIT;
