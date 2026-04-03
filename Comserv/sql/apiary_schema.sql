-- Apiary Management System Database Schema
-- File: apiary_schema.sql,v 1.0 2025/01/27 shanta Exp shanta
-- Purpose: Normalized database structure for modern apiary management
-- Replaces: Denormalized ApisQueenLogTb structure

-- Enable foreign key constraints
SET FOREIGN_KEY_CHECKS = 1;

-- ============================================================================
-- CORE APIARY TABLES
-- ============================================================================

-- Hives table - Main hive records
CREATE TABLE IF NOT EXISTS hives (
    id INT AUTO_INCREMENT PRIMARY KEY,
    hive_number VARCHAR(50) NOT NULL,
    yard_id INT NOT NULL,
    pallet_code VARCHAR(20),
    queen_code VARCHAR(30),
    status ENUM('active', 'inactive', 'dead', 'split', 'combined') DEFAULT 'active',
    owner VARCHAR(30),
    sitename VARCHAR(30),
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    created_by VARCHAR(50),
    updated_by VARCHAR(50),
    
    FOREIGN KEY (yard_id) REFERENCES yards(id) ON DELETE RESTRICT,
    UNIQUE KEY unique_hive_yard (hive_number, yard_id),
    INDEX idx_pallet_code (pallet_code),
    INDEX idx_queen_code (queen_code),
    INDEX idx_status (status),
    INDEX idx_owner (owner)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Boxes table - Hive boxes/supers
CREATE TABLE IF NOT EXISTS boxes (
    id INT AUTO_INCREMENT PRIMARY KEY,
    hive_id INT NOT NULL,
    box_position INT NOT NULL COMMENT '1=bottom, 2=middle, 3=top, etc.',
    box_type ENUM('brood', 'super', 'honey', 'deep', 'medium', 'shallow') DEFAULT 'brood',
    box_size ENUM('deep', 'medium', 'shallow') DEFAULT 'deep',
    foundation_type ENUM('wired', 'unwired', 'plastic', 'natural') DEFAULT 'wired',
    status ENUM('active', 'removed', 'stored') DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    created_by VARCHAR(50),
    updated_by VARCHAR(50),
    
    FOREIGN KEY (hive_id) REFERENCES hives(id) ON DELETE CASCADE,
    UNIQUE KEY unique_hive_position (hive_id, box_position),
    INDEX idx_box_type (box_type),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Frames table - Individual frames within boxes
CREATE TABLE IF NOT EXISTS frames (
    id INT AUTO_INCREMENT PRIMARY KEY,
    box_id INT NOT NULL,
    frame_position INT NOT NULL COMMENT '1-10 typically',
    frame_type ENUM('brood', 'honey', 'pollen', 'empty', 'foundation') DEFAULT 'foundation',
    foundation_type ENUM('wired', 'unwired', 'plastic', 'natural') DEFAULT 'wired',
    comb_condition ENUM('new', 'good', 'fair', 'poor', 'damaged') DEFAULT 'new',
    status ENUM('active', 'removed', 'stored') DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    created_by VARCHAR(50),
    updated_by VARCHAR(50),
    
    FOREIGN KEY (box_id) REFERENCES boxes(id) ON DELETE CASCADE,
    UNIQUE KEY unique_box_position (box_id, frame_position),
    INDEX idx_frame_type (frame_type),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- INSPECTION SYSTEM
-- ============================================================================

-- Inspections table - Main inspection records
CREATE TABLE IF NOT EXISTS inspections (
    id INT AUTO_INCREMENT PRIMARY KEY,
    hive_id INT NOT NULL,
    inspection_date DATE NOT NULL,
    start_time TIME,
    end_time TIME,
    weather_conditions VARCHAR(100),
    temperature DECIMAL(5,2),
    inspector VARCHAR(50) NOT NULL,
    inspection_type ENUM('routine', 'disease_check', 'harvest', 'treatment', 'emergency') DEFAULT 'routine',
    overall_status ENUM('excellent', 'good', 'fair', 'poor', 'critical') DEFAULT 'good',
    queen_seen BOOLEAN DEFAULT FALSE,
    queen_marked BOOLEAN DEFAULT FALSE,
    eggs_seen BOOLEAN DEFAULT FALSE,
    larvae_seen BOOLEAN DEFAULT FALSE,
    capped_brood_seen BOOLEAN DEFAULT FALSE,
    supersedure_cells INT DEFAULT 0,
    swarm_cells INT DEFAULT 0,
    queen_cells INT DEFAULT 0,
    population_estimate ENUM('very_strong', 'strong', 'moderate', 'weak', 'very_weak'),
    temperament ENUM('calm', 'moderate', 'aggressive', 'very_aggressive') DEFAULT 'calm',
    general_notes TEXT,
    action_required TEXT,
    next_inspection_date DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    FOREIGN KEY (hive_id) REFERENCES hives(id) ON DELETE CASCADE,
    INDEX idx_inspection_date (inspection_date),
    INDEX idx_inspector (inspector),
    INDEX idx_inspection_type (inspection_type),
    INDEX idx_overall_status (overall_status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Inspection Details table - Detailed findings per frame/box
CREATE TABLE IF NOT EXISTS inspection_details (
    id INT AUTO_INCREMENT PRIMARY KEY,
    inspection_id INT NOT NULL,
    box_id INT,
    frame_id INT,
    detail_type ENUM('box_summary', 'frame_detail') NOT NULL,
    
    -- Content measurements
    bees_coverage ENUM('none', 'light', 'moderate', 'heavy', 'full') DEFAULT 'none',
    brood_pattern ENUM('excellent', 'good', 'fair', 'poor', 'spotty') DEFAULT 'good',
    brood_type ENUM('eggs', 'larvae', 'capped', 'mixed') DEFAULT 'mixed',
    brood_percentage INT DEFAULT 0 COMMENT 'Percentage of frame with brood',
    honey_percentage INT DEFAULT 0 COMMENT 'Percentage of frame with honey',
    pollen_percentage INT DEFAULT 0 COMMENT 'Percentage of frame with pollen',
    empty_percentage INT DEFAULT 0 COMMENT 'Percentage of frame empty',
    
    -- Conditions and issues
    comb_condition ENUM('excellent', 'good', 'fair', 'poor', 'damaged') DEFAULT 'good',
    disease_signs TEXT,
    pest_signs TEXT,
    queen_cells_count INT DEFAULT 0,
    drone_cells_count INT DEFAULT 0,
    
    -- Actions taken
    foundation_added BOOLEAN DEFAULT FALSE,
    comb_removed BOOLEAN DEFAULT FALSE,
    honey_harvested BOOLEAN DEFAULT FALSE,
    treatment_applied VARCHAR(100),
    
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (inspection_id) REFERENCES inspections(id) ON DELETE CASCADE,
    FOREIGN KEY (box_id) REFERENCES boxes(id) ON DELETE SET NULL,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE SET NULL,
    INDEX idx_detail_type (detail_type),
    INDEX idx_brood_pattern (brood_pattern),
    INDEX idx_comb_condition (comb_condition)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- MANAGEMENT AND TRACKING
-- ============================================================================

-- Hive Movements table - Track box/frame movements between hives
CREATE TABLE IF NOT EXISTS hive_movements (
    id INT AUTO_INCREMENT PRIMARY KEY,
    movement_date DATE NOT NULL,
    movement_type ENUM('box_transfer', 'frame_transfer', 'hive_split', 'hive_combine') NOT NULL,
    
    -- Source information
    source_hive_id INT,
    source_box_id INT,
    source_frame_id INT,
    
    -- Destination information
    destination_hive_id INT,
    destination_box_id INT,
    destination_box_position INT,
    destination_frame_position INT,
    
    quantity INT DEFAULT 1,
    reason VARCHAR(200),
    performed_by VARCHAR(50) NOT NULL,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (source_hive_id) REFERENCES hives(id) ON DELETE SET NULL,
    FOREIGN KEY (source_box_id) REFERENCES boxes(id) ON DELETE SET NULL,
    FOREIGN KEY (source_frame_id) REFERENCES frames(id) ON DELETE SET NULL,
    FOREIGN KEY (destination_hive_id) REFERENCES hives(id) ON DELETE SET NULL,
    FOREIGN KEY (destination_box_id) REFERENCES boxes(id) ON DELETE SET NULL,
    INDEX idx_movement_date (movement_date),
    INDEX idx_movement_type (movement_type),
    INDEX idx_performed_by (performed_by)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Honey Harvest table - Track honey production
CREATE TABLE IF NOT EXISTS honey_harvests (
    id INT AUTO_INCREMENT PRIMARY KEY,
    hive_id INT NOT NULL,
    harvest_date DATE NOT NULL,
    box_id INT,
    frame_id INT,
    honey_type ENUM('spring', 'summer', 'fall', 'wildflower', 'clover', 'basswood', 'other') DEFAULT 'wildflower',
    weight_kg DECIMAL(8,3),
    weight_lbs DECIMAL(8,3),
    moisture_content DECIMAL(4,1),
    quality_grade ENUM('grade_a', 'grade_b', 'grade_c', 'comb_honey') DEFAULT 'grade_a',
    harvested_by VARCHAR(50) NOT NULL,
    processing_notes TEXT,
    storage_location VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (hive_id) REFERENCES hives(id) ON DELETE CASCADE,
    FOREIGN KEY (box_id) REFERENCES boxes(id) ON DELETE SET NULL,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE SET NULL,
    INDEX idx_harvest_date (harvest_date),
    INDEX idx_honey_type (honey_type),
    INDEX idx_harvested_by (harvested_by)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Treatments table - Track treatments and medications
CREATE TABLE IF NOT EXISTS treatments (
    id INT AUTO_INCREMENT PRIMARY KEY,
    hive_id INT NOT NULL,
    treatment_date DATE NOT NULL,
    treatment_type ENUM('varroa', 'nosema', 'foulbrood', 'tracheal_mite', 'small_hive_beetle', 'wax_moth', 'other') NOT NULL,
    product_name VARCHAR(100) NOT NULL,
    dosage VARCHAR(50),
    application_method ENUM('strip', 'drench', 'dust', 'spray', 'fumigation', 'feeding') NOT NULL,
    duration_days INT,
    withdrawal_period_days INT,
    effectiveness ENUM('excellent', 'good', 'fair', 'poor', 'unknown') DEFAULT 'unknown',
    applied_by VARCHAR(50) NOT NULL,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    FOREIGN KEY (hive_id) REFERENCES hives(id) ON DELETE CASCADE,
    INDEX idx_treatment_date (treatment_date),
    INDEX idx_treatment_type (treatment_type),
    INDEX idx_applied_by (applied_by)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- LEGACY DATA MIGRATION SUPPORT
-- ============================================================================

-- Migration Log table - Track data migration from ApisQueenLogTb
CREATE TABLE IF NOT EXISTS migration_log (
    id INT AUTO_INCREMENT PRIMARY KEY,
    legacy_record_id INT NOT NULL COMMENT 'Original record_id from ApisQueenLogTb',
    migration_type ENUM('hive_created', 'inspection_created', 'data_extracted', 'error') NOT NULL,
    new_record_type ENUM('hive', 'inspection', 'inspection_detail', 'movement', 'harvest') NOT NULL,
    new_record_id INT NOT NULL,
    migration_notes TEXT,
    migrated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    migrated_by VARCHAR(50) DEFAULT 'system',
    
    INDEX idx_legacy_record_id (legacy_record_id),
    INDEX idx_migration_type (migration_type),
    INDEX idx_new_record_type (new_record_type),
    INDEX idx_migrated_at (migrated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Legacy Data Mapping table - Maintain mapping between old and new structures
CREATE TABLE IF NOT EXISTS legacy_data_mapping (
    id INT AUTO_INCREMENT PRIMARY KEY,
    legacy_table VARCHAR(50) NOT NULL DEFAULT 'apis_queen_log_tb',
    legacy_record_id INT NOT NULL,
    legacy_field VARCHAR(50) NOT NULL,
    legacy_value TEXT,
    
    new_table VARCHAR(50) NOT NULL,
    new_record_id INT NOT NULL,
    new_field VARCHAR(50) NOT NULL,
    new_value TEXT,
    
    mapping_confidence ENUM('high', 'medium', 'low') DEFAULT 'medium',
    mapping_notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    
    INDEX idx_legacy_record (legacy_table, legacy_record_id),
    INDEX idx_new_record (new_table, new_record_id),
    INDEX idx_mapping_confidence (mapping_confidence)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- VIEWS FOR COMMON QUERIES
-- ============================================================================

-- Hive Overview View - Complete hive information with current status
CREATE OR REPLACE VIEW hive_overview AS
SELECT 
    h.id as hive_id,
    h.hive_number,
    h.pallet_code,
    h.queen_code,
    h.status as hive_status,
    h.owner,
    h.sitename,
    y.name as yard_name,
    s.name as site_name,
    COUNT(DISTINCT b.id) as box_count,
    COUNT(DISTINCT f.id) as frame_count,
    MAX(i.inspection_date) as last_inspection_date,
    h.created_at,
    h.updated_at
FROM hives h
LEFT JOIN yards y ON h.yard_id = y.id
LEFT JOIN sites s ON y.site_id = s.id
LEFT JOIN boxes b ON h.id = b.hive_id AND b.status = 'active'
LEFT JOIN frames f ON b.id = f.box_id AND f.status = 'active'
LEFT JOIN inspections i ON h.id = i.hive_id
WHERE h.status IN ('active', 'inactive')
GROUP BY h.id, h.hive_number, h.pallet_code, h.queen_code, h.status, h.owner, h.sitename, y.name, s.name, h.created_at, h.updated_at;

-- Latest Inspection View - Most recent inspection data per hive
CREATE OR REPLACE VIEW latest_inspections AS
SELECT 
    i.*,
    h.hive_number,
    h.pallet_code,
    h.queen_code,
    y.name as yard_name,
    s.name as site_name
FROM inspections i
INNER JOIN (
    SELECT hive_id, MAX(inspection_date) as max_date
    FROM inspections
    GROUP BY hive_id
) latest ON i.hive_id = latest.hive_id AND i.inspection_date = latest.max_date
LEFT JOIN hives h ON i.hive_id = h.id
LEFT JOIN yards y ON h.yard_id = y.id
LEFT JOIN sites s ON y.site_id = s.id;

-- ============================================================================
-- INITIAL DATA AND CONSTRAINTS
-- ============================================================================

-- Add some initial constraint checks
ALTER TABLE inspection_details 
ADD CONSTRAINT chk_percentages 
CHECK (brood_percentage + honey_percentage + pollen_percentage + empty_percentage <= 100);

-- Add triggers for audit trail (optional, can be added later)
-- These would track changes to critical tables for compliance

-- Create indexes for performance
CREATE INDEX idx_hives_created_at ON hives(created_at);
CREATE INDEX idx_inspections_hive_date ON inspections(hive_id, inspection_date);
CREATE INDEX idx_inspection_details_inspection ON inspection_details(inspection_id);
CREATE INDEX idx_movements_date_type ON hive_movements(movement_date, movement_type);

-- Set initial auto-increment values to avoid conflicts
ALTER TABLE hives AUTO_INCREMENT = 1000;
ALTER TABLE boxes AUTO_INCREMENT = 1000;
ALTER TABLE frames AUTO_INCREMENT = 1000;
ALTER TABLE inspections AUTO_INCREMENT = 1000;
ALTER TABLE inspection_details AUTO_INCREMENT = 1000;

COMMIT;