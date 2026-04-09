-- Unified Inventory BOM migration
-- Extends inventory_items with item_origin tracking and adds a generic BOM table.
-- Also converts hive_components / boxes / hive_frames to reference inventory_items
-- instead of the now-deprecated bee_equipment_types.
--
-- Run order:
--   1. inventory_tables.sql     (creates inventory_items and related tables)
--   2. apiary_schema.sql        (creates hives, boxes, hive_frames)
--   3. bee_equipment_bom.sql    (SKIP — replaced by this file)
--   4. THIS FILE

SET FOREIGN_KEY_CHECKS = 1;

-- ============================================================================
-- ALTER inventory_items: add item_origin and is_assemblable
-- ============================================================================

ALTER TABLE `inventory_items`
  ADD COLUMN IF NOT EXISTS `item_origin` VARCHAR(50) NOT NULL DEFAULT 'purchased'
    COMMENT 'purchased | grown | foraged | manufactured | 3d_printed | harvested | crafted | other'
    AFTER `category`,
  ADD COLUMN IF NOT EXISTS `is_assemblable` TINYINT(1) NOT NULL DEFAULT 0
    COMMENT '1 if this item has a BOM (is made from other items)'
    AFTER `item_origin`,
  ADD KEY IF NOT EXISTS `idx_item_origin` (`item_origin`),
  ADD KEY IF NOT EXISTS `idx_is_assemblable` (`is_assemblable`);

-- ============================================================================
-- GENERIC BILL OF MATERIALS
-- Any item can have a recipe / parts list referencing other inventory items.
-- Works for: frames, boxes, honey jars, wooden cabinets, 3D prints,
--            herb bundles, tractor service kits, potato bags, painted art, etc.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `inventory_item_bom` (
  `id`                INT NOT NULL AUTO_INCREMENT,
  `parent_item_id`    INT NOT NULL
                      COMMENT 'The finished/assembled item',
  `component_item_id` INT NOT NULL
                      COMMENT 'The raw material or sub-component',
  `quantity`          DECIMAL(12,4) NOT NULL DEFAULT 1.0000
                      COMMENT 'Amount of component per ONE unit of parent',
  `unit`              VARCHAR(30) NOT NULL DEFAULT 'each'
                      COMMENT 'each | g | kg | ml | L | cm | m | sheet | hour',
  `is_optional`       TINYINT(1) NOT NULL DEFAULT 0
                      COMMENT '1 = optional ingredient (foundation, paint, etc.)',
  `scrap_factor`      DECIMAL(5,4) DEFAULT 0.0000
                      COMMENT 'Extra material fraction for waste (0.05 = 5%)',
  `sort_order`        INT DEFAULT 0,
  `notes`             TEXT,
  `created_at`        DATETIME,
  `updated_at`        DATETIME,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_parent_component` (`parent_item_id`, `component_item_id`),
  KEY `idx_parent_item_id` (`parent_item_id`),
  KEY `idx_component_item_id` (`component_item_id`),
  CONSTRAINT `fk_bom_parent`
    FOREIGN KEY (`parent_item_id`) REFERENCES `inventory_items` (`id`)
    ON DELETE CASCADE,
  CONSTRAINT `fk_bom_component`
    FOREIGN KEY (`component_item_id`) REFERENCES `inventory_items` (`id`)
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- HIVE COMPONENT INSTANCES
-- Physical instances of hive accessories (bottom boards, covers, feeders, etc.)
-- Each references an inventory_item that defines its type and BOM.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `hive_components` (
  `id`                INT NOT NULL AUTO_INCREMENT,
  `hive_id`           INT DEFAULT NULL
                      COMMENT 'Hive currently using this component (NULL = stored)',
  `inventory_item_id` INT NOT NULL
                      COMMENT 'FK → inventory_items — defines type and BOM',
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
  KEY `idx_inventory_item_id` (`inventory_item_id`),
  KEY `idx_status` (`status`),
  KEY `idx_condition` (`condition`),
  KEY `idx_sitename` (`sitename`),
  CONSTRAINT `fk_hc_hive`
    FOREIGN KEY (`hive_id`) REFERENCES `hives` (`id`)
    ON DELETE SET NULL,
  CONSTRAINT `fk_hc_item`
    FOREIGN KEY (`inventory_item_id`) REFERENCES `inventory_items` (`id`)
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- ALTER boxes and hive_frames: add inventory_item_id
-- (replaces equipment_type_id from the deprecated bee_equipment_types table)
-- ============================================================================

ALTER TABLE `boxes`
  ADD COLUMN IF NOT EXISTS `inventory_item_id` INT DEFAULT NULL
    COMMENT 'FK → inventory_items (e.g. Deep Box 10-frame) for BOM lookup'
    AFTER `updated_by`,
  ADD KEY IF NOT EXISTS `idx_boxes_inv_item` (`inventory_item_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_box_inv_item`
    FOREIGN KEY (`inventory_item_id`) REFERENCES `inventory_items` (`id`)
    ON DELETE SET NULL;

ALTER TABLE `hive_frames`
  ADD COLUMN IF NOT EXISTS `inventory_item_id` INT DEFAULT NULL
    COMMENT 'FK → inventory_items (e.g. Standard Deep Frame) for BOM lookup'
    AFTER `updated_by`,
  ADD COLUMN IF NOT EXISTS `has_foundation` TINYINT(1) NOT NULL DEFAULT 0
    COMMENT 'Whether foundation is currently installed in this frame',
  ADD KEY IF NOT EXISTS `idx_frames_inv_item` (`inventory_item_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_frame_inv_item`
    FOREIGN KEY (`inventory_item_id`) REFERENCES `inventory_items` (`id`)
    ON DELETE SET NULL;

-- ============================================================================
-- DROP deprecated bee_equipment tables if they exist
-- (Only safe after confirming no production data; adjust as needed)
-- ============================================================================

-- DROP TABLE IF EXISTS `bee_equipment_bom`;
-- DROP TABLE IF EXISTS `bee_equipment_types`;

-- ============================================================================
-- SEED DATA: Inventory items for common beekeeping equipment types
-- These replace the old bee_equipment_types seed data.
-- Adjust sitename to match your installation.
-- ============================================================================

INSERT IGNORE INTO `inventory_items`
  (`sitename`, `sku`, `name`, `category`, `item_origin`, `is_assemblable`, `unit_of_measure`, `status`)
VALUES
  ('CSC', 'APIARY-FRAME-DEEP',   'Standard Deep Frame',         'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-FRAME-MED',    'Standard Medium Frame',        'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-FRAME-SH',     'Standard Shallow Frame',       'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-BOX-DEEP10',   'Deep Box 10-frame',            'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-BOX-MED10',    'Medium Box 10-frame',          'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-BOX-SH10',     'Shallow Box 10-frame',         'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-BOX-DEEP8',    'Deep Box 8-frame',             'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-NUC5',         '5-Frame Nuc Box',              'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-BB-SCREEN',    'Screened Bottom Board',        'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-BB-SOLID',     'Solid Bottom Board',           'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-COVER-INNER',  'Standard Inner Cover',         'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-COVER-TELE',   'Telescoping Outer Cover',      'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-COVER-MIG',    'Migratory Outer Cover',        'Apiary', 'manufactured', 1, 'each', 'active'),
  ('CSC', 'APIARY-FEEDER-TOP',   'Top Hive Feeder',              'Apiary', 'purchased',    0, 'each', 'active'),
  ('CSC', 'APIARY-FEEDER-BOARD', 'Boardman Entrance Feeder',     'Apiary', 'purchased',    0, 'each', 'active'),
  ('CSC', 'APIARY-QX-WIRE',      'Wire Queen Excluder',          'Apiary', 'purchased',    0, 'each', 'active'),
  ('CSC', 'APIARY-QX-PLASTIC',   'Plastic Queen Excluder',       'Apiary', 'purchased',    0, 'each', 'active'),
  -- Raw materials / components used in BOM
  ('CSC', 'APIARY-TOP-BAR-DEEP', 'Top Bar (Deep)',               'Apiary Parts', 'purchased', 0, 'each', 'active'),
  ('CSC', 'APIARY-BOT-BAR',      'Bottom Bar',                   'Apiary Parts', 'purchased', 0, 'each', 'active'),
  ('CSC', 'APIARY-END-BAR-DEEP', 'End Bar (Deep)',               'Apiary Parts', 'purchased', 0, 'each', 'active'),
  ('CSC', 'APIARY-END-BAR-MED',  'End Bar (Medium)',             'Apiary Parts', 'purchased', 0, 'each', 'active'),
  ('CSC', 'APIARY-FOUNDATION-D', 'Foundation Sheet (Deep)',      'Apiary Parts', 'purchased', 0, 'each', 'active'),
  ('CSC', 'APIARY-FOUNDATION-M', 'Foundation Sheet (Medium)',    'Apiary Parts', 'purchased', 0, 'each', 'active'),
  ('CSC', 'NAIL-1.5',            'Nail 1.5 inch galvanized',     'Hardware',     'purchased', 0, 'each', 'active'),
  ('CSC', 'NAIL-2.0',            'Nail 2 inch galvanized',       'Hardware',     'purchased', 0, 'each', 'active'),
  ('CSC', 'PANEL-SIDE-DEEP',     'Side Panel (Deep Box)',        'Lumber',       'purchased', 0, 'each', 'active'),
  ('CSC', 'PANEL-END-DEEP',      'End Panel (Deep Box)',         'Lumber',       'purchased', 0, 'each', 'active'),
  ('CSC', 'PAINT-EXT',           'Exterior Paint/Finish',        'Supplies',     'purchased', 0, 'litre','active');

-- BOM: Standard Deep Frame
INSERT IGNORE INTO `inventory_item_bom`
  (`parent_item_id`, `component_item_id`, `quantity`, `unit`, `is_optional`, `sort_order`)
SELECT p.id, c.id, qty, unit, opt, ord FROM (
  SELECT 'APIARY-FRAME-DEEP' as psku, 'APIARY-TOP-BAR-DEEP' as csku, 1     as qty, 'each'  as unit, 0 as opt, 1 as ord UNION ALL
  SELECT 'APIARY-FRAME-DEEP',          'APIARY-BOT-BAR',             1,         'each',          0,        2 UNION ALL
  SELECT 'APIARY-FRAME-DEEP',          'APIARY-END-BAR-DEEP',        2,         'each',          0,        3 UNION ALL
  SELECT 'APIARY-FRAME-DEEP',          'NAIL-1.5',                   24,        'each',          0,        4 UNION ALL
  SELECT 'APIARY-FRAME-DEEP',          'APIARY-FOUNDATION-D',        1,         'each',          1,        5
) bom
JOIN inventory_items p ON p.sku = bom.psku
JOIN inventory_items c ON c.sku = bom.csku;

-- BOM: Standard Medium Frame
INSERT IGNORE INTO `inventory_item_bom`
  (`parent_item_id`, `component_item_id`, `quantity`, `unit`, `is_optional`, `sort_order`)
SELECT p.id, c.id, qty, unit, opt, ord FROM (
  SELECT 'APIARY-FRAME-MED' as psku, 'APIARY-TOP-BAR-DEEP'  as csku, 1  as qty, 'each' as unit, 0 as opt, 1 as ord UNION ALL
  SELECT 'APIARY-FRAME-MED',          'APIARY-BOT-BAR',              1,          'each',         0,        2 UNION ALL
  SELECT 'APIARY-FRAME-MED',          'APIARY-END-BAR-MED',          2,          'each',         0,        3 UNION ALL
  SELECT 'APIARY-FRAME-MED',          'NAIL-1.5',                    20,         'each',         0,        4 UNION ALL
  SELECT 'APIARY-FRAME-MED',          'APIARY-FOUNDATION-M',         1,          'each',         1,        5
) bom
JOIN inventory_items p ON p.sku = bom.psku
JOIN inventory_items c ON c.sku = bom.csku;

-- BOM: Deep Box 10-frame
INSERT IGNORE INTO `inventory_item_bom`
  (`parent_item_id`, `component_item_id`, `quantity`, `unit`, `is_optional`, `sort_order`)
SELECT p.id, c.id, qty, unit, opt, ord FROM (
  SELECT 'APIARY-BOX-DEEP10' as psku, 'PANEL-SIDE-DEEP' as csku, 2    as qty, 'each'  as unit, 0 as opt, 1 as ord UNION ALL
  SELECT 'APIARY-BOX-DEEP10',          'PANEL-END-DEEP',          2,           'each',          0,        2 UNION ALL
  SELECT 'APIARY-BOX-DEEP10',          'NAIL-2.0',                40,          'each',          0,        3 UNION ALL
  SELECT 'APIARY-BOX-DEEP10',          'PAINT-EXT',               0.25,        'litre',         1,        4
) bom
JOIN inventory_items p ON p.sku = bom.psku
JOIN inventory_items c ON c.sku = bom.csku;

COMMIT;
