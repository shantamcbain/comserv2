-- Queen Log Data Model — Schema Migration
-- File: 009_queen_log_schema.sql
-- DB Project: 219 (QueenLogModel) under Apiary Management System (91)
-- Todos: 793, 794, 795, 796
-- Apply via: /admin/schema_comparison (Result class driven) or directly to ency DB

-- NOTE: All Result class definitions are the canonical source of truth.
-- This file documents the SQL equivalent for DBA review and /admin/schema_comparison.
-- Do NOT apply directly without reviewing against live schema.

SET FOREIGN_KEY_CHECKS = 0;

-- ============================================================================
-- TODO 793: Extend queens table with full lifecycle management fields
-- ============================================================================
-- The queens table already exists from apiary_schema.sql (basic form).
-- This migration adds the extended fields defined in Queen.pm Result class.

CREATE TABLE IF NOT EXISTS queens (
    id INT AUTO_INCREMENT PRIMARY KEY,
    tag_number VARCHAR(50) NOT NULL COMMENT 'Unique identifier / physical tag on the queen',
    birth_date DATE COMMENT 'Date queen emerged or was estimated to have emerged',
    breed VARCHAR(100) COMMENT 'Breed or race (e.g. Italian, Carniolan, Buckfast)',
    genetic_line VARCHAR(100) COMMENT 'Named breeding line within the breed',
    color_marking VARCHAR(50) COMMENT 'Physical colour dot or paint marking on thorax',
    origin VARCHAR(100) COMMENT 'Source / breeder of the queen',
    parent_queen_id INT COMMENT 'Mother queen — self-referential FK for genetic lineage tracking',
    drone_source VARCHAR(100) COMMENT 'Description or tag of drone source used for mating',
    mating_status ENUM('virgin','mated','laying','drone_layer','superseded','missing','dead') NOT NULL DEFAULT 'virgin' COMMENT 'Current mating and laying lifecycle status',
    laying_status ENUM('laying_well','laying_poor','not_laying','drone_layer','superseded','missing') COMMENT 'Quality of current laying pattern',
    performance_rating INT COMMENT 'Subjective performance score 1-10',
    temperament_rating ENUM('calm','moderate','aggressive','very_aggressive') NOT NULL DEFAULT 'calm',
    health_status ENUM('healthy','diseased','injured','missing','dead') NOT NULL DEFAULT 'healthy',
    current_yard_id INT COMMENT 'FK → yards — current yard location (denormalised for quick lookup)',
    current_pallet_id INT COMMENT 'FK → pallets — current pallet (denormalised)',
    current_position INT COMMENT 'Position on pallet (1-based from left)',
    current_hive_configuration_id INT COMMENT 'FK → hive_configurations — active hive configuration',
    purpose ENUM('production','breeding','replacement','sale','research') NOT NULL DEFAULT 'production',
    introduction_date DATE COMMENT 'Date queen was introduced to her current hive',
    removal_date DATE COMMENT 'Date queen was removed, superseded, or died',
    acquisition_cost DECIMAL(8,2),
    acquisition_date DATE,
    status ENUM('active','inactive','sold','dead','missing') NOT NULL DEFAULT 'active',
    comments TEXT COMMENT 'General notes (kept for backward compatibility)',
    notes TEXT COMMENT 'Detailed notes on this queen',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    created_by VARCHAR(50),
    updated_by VARCHAR(50),

    UNIQUE KEY tag_number_unique (tag_number),
    FOREIGN KEY (parent_queen_id) REFERENCES queens(id) ON DELETE SET NULL,
    FOREIGN KEY (current_yard_id) REFERENCES yards(id) ON DELETE SET NULL,
    FOREIGN KEY (current_hive_configuration_id) REFERENCES hive_configurations(id) ON DELETE SET NULL,
    INDEX idx_status (status),
    INDEX idx_mating_status (mating_status),
    INDEX idx_current_yard (current_yard_id),
    INDEX idx_purpose (purpose)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- If queens table already exists (basic form), apply ALTER to add missing columns:
-- ALTER TABLE queens
--     ADD COLUMN genetic_line VARCHAR(100) AFTER breed,
--     ADD COLUMN color_marking VARCHAR(50) AFTER genetic_line,
--     ADD COLUMN parent_queen_id INT AFTER origin,
--     ADD COLUMN drone_source VARCHAR(100) AFTER parent_queen_id,
--     ADD COLUMN laying_status ENUM('laying_well','laying_poor','not_laying','drone_layer','superseded','missing') AFTER mating_status,
--     ADD COLUMN current_yard_id INT AFTER performance_rating,
--     ADD COLUMN current_pallet_id INT AFTER current_yard_id,
--     ADD COLUMN current_position INT AFTER current_pallet_id,
--     ADD COLUMN current_hive_configuration_id INT AFTER current_position,
--     ADD COLUMN purpose ENUM('production','breeding','replacement','sale','research') NOT NULL DEFAULT 'production' AFTER current_hive_configuration_id,
--     ADD COLUMN acquisition_cost DECIMAL(8,2) AFTER removal_date,
--     ADD COLUMN acquisition_date DATE AFTER acquisition_cost,
--     ADD COLUMN updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP AFTER created_at,
--     ADD COLUMN created_by VARCHAR(50) AFTER updated_at,
--     ADD COLUMN updated_by VARCHAR(50) AFTER created_by,
--     ADD UNIQUE KEY tag_number_unique (tag_number),
--     ADD CONSTRAINT fk_queen_parent FOREIGN KEY (parent_queen_id) REFERENCES queens(id) ON DELETE SET NULL,
--     ADD CONSTRAINT fk_queen_yard FOREIGN KEY (current_yard_id) REFERENCES yards(id) ON DELETE SET NULL;

-- ============================================================================
-- TODO 794: Create queen_events table
-- ============================================================================

CREATE TABLE IF NOT EXISTS queen_events (
    id INT AUTO_INCREMENT PRIMARY KEY,
    queen_id INT NOT NULL COMMENT 'FK → queens',
    event_type ENUM(
        'grafted','emerged','mated','introduced','superseded',
        'replaced','dead','sold','treated','moved',
        'marked','clipped','inspected'
    ) NOT NULL COMMENT 'Type of lifecycle event',
    event_date DATE NOT NULL COMMENT 'Date the event occurred',
    hive_id INT COMMENT 'FK → hives — hive where event occurred (nullable)',
    yard_id INT COMMENT 'FK → yards — yard where event occurred (nullable)',
    inspector VARCHAR(50) COMMENT 'Username of person recording the event',
    notes TEXT COMMENT 'Free-form notes about this event',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(50),

    FOREIGN KEY (queen_id) REFERENCES queens(id) ON DELETE CASCADE,
    FOREIGN KEY (hive_id) REFERENCES hives(id) ON DELETE SET NULL,
    FOREIGN KEY (yard_id) REFERENCES yards(id) ON DELETE SET NULL,
    INDEX idx_queen_id (queen_id),
    INDEX idx_event_type (event_type),
    INDEX idx_event_date (event_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- TODO 795: Create queen_hive_assignments table
-- ============================================================================

CREATE TABLE IF NOT EXISTS queen_hive_assignments (
    id INT AUTO_INCREMENT PRIMARY KEY,
    queen_id INT NOT NULL COMMENT 'FK → queens',
    hive_id INT NOT NULL COMMENT 'FK → hives',
    yard_id INT COMMENT 'FK → yards — denormalised from hive.yard_id for reporting',
    assigned_date DATE NOT NULL COMMENT 'Date queen was introduced / moved into this hive',
    removed_date DATE COMMENT 'Date queen left this hive (NULL = currently assigned)',
    reason VARCHAR(100) COMMENT 'Reason for introduction or removal',
    notes TEXT,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by VARCHAR(50),
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    updated_by VARCHAR(50),

    FOREIGN KEY (queen_id) REFERENCES queens(id) ON DELETE CASCADE,
    FOREIGN KEY (hive_id) REFERENCES hives(id) ON DELETE CASCADE,
    FOREIGN KEY (yard_id) REFERENCES yards(id) ON DELETE SET NULL,
    INDEX idx_queen_id (queen_id),
    INDEX idx_hive_id (hive_id),
    INDEX idx_active_assignments (hive_id, removed_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- TODO 796: Add queen_id FK to inspections table
-- ============================================================================

-- If inspections table exists, add the queen_id column:
-- ALTER TABLE inspections
--     ADD COLUMN queen_id INT COMMENT 'FK → queens — queen confirmed present during this inspection (nullable)'
--         AFTER temperature,
--     ADD CONSTRAINT fk_inspection_queen FOREIGN KEY (queen_id) REFERENCES queens(id) ON DELETE SET NULL,
--     ADD INDEX idx_queen_id (queen_id);

-- Full inspections table definition already includes queen_id (see apiary_schema.sql).
-- The column was added to the CREATE TABLE IF NOT EXISTS definition below for reference:
-- queen_id INT COMMENT 'FK → queens — queen confirmed present during this inspection (nullable)',

SET FOREIGN_KEY_CHECKS = 1;
