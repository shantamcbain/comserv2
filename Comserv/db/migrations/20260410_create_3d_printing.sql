-- Migration: 20260410_create_3d_printing.sql
-- Purpose: Create tables for the 3D Printing site module
-- Author: Shanta / AI Assistant
-- Date: 2026-04-10

-- ============================================================
-- 3D Printer Farm
-- ============================================================
CREATE TABLE IF NOT EXISTS printing_3d_printers (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    sitename        VARCHAR(100) NOT NULL,
    name            VARCHAR(255) NOT NULL,
    model           VARCHAR(255),
    status          ENUM('idle','printing','maintenance','offline') NOT NULL DEFAULT 'idle',
    nozzle_diameter DECIMAL(4,2) DEFAULT 0.40,
    bed_size        VARCHAR(100),
    notes           TEXT,
    current_job_id  INT,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_printers_sitename (sitename),
    INDEX idx_printers_status   (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ============================================================
-- 3D Model Catalog (metadata cache)
-- ============================================================
CREATE TABLE IF NOT EXISTS printing_3d_models (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    sitename       VARCHAR(100) NOT NULL,
    name           VARCHAR(255) NOT NULL,
    description    TEXT,
    file_id        INT,          -- FK to files.id (FileManager DB)
    nfs_path       VARCHAR(1000),
    file_type      VARCHAR(20),  -- stl, obj, gcode, 3mf, step, iges
    tags           VARCHAR(500),
    thumbnail_url  VARCHAR(1000),
    source         ENUM('filemanager','nfs','web') DEFAULT 'filemanager',
    source_url     VARCHAR(1000),
    added_by       VARCHAR(255),
    is_active      TINYINT(1) DEFAULT 1,
    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_models_sitename (sitename),
    INDEX idx_models_file_id  (file_id),
    INDEX idx_models_active   (is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ============================================================
-- 3D Print Jobs / Queue
-- ============================================================
CREATE TABLE IF NOT EXISTS printing_3d_jobs (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    sitename        VARCHAR(100) NOT NULL,
    model_id        INT NOT NULL,
    user_id         INT NOT NULL,
    username        VARCHAR(255),
    printer_id      INT,
    status          ENUM('queued','assigned','printing','completed','cancelled','failed') NOT NULL DEFAULT 'queued',
    filament_color  VARCHAR(100),
    filament_type   VARCHAR(100),
    quantity        INT DEFAULT 1,
    notes           TEXT,
    admin_notes     TEXT,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    started_at      DATETIME,
    completed_at    DATETIME,
    INDEX idx_jobs_sitename   (sitename),
    INDEX idx_jobs_user_id    (user_id),
    INDEX idx_jobs_printer_id (printer_id),
    INDEX idx_jobs_status     (status),
    CONSTRAINT fk_job_model   FOREIGN KEY (model_id)   REFERENCES printing_3d_models (id),
    CONSTRAINT fk_job_printer FOREIGN KEY (printer_id) REFERENCES printing_3d_printers (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ============================================================
-- Ensure site_modules table has a 3d_printing row capability
-- (site_modules table already exists; no CREATE needed)
-- Admins add rows via the UI or admin scripts.
-- ============================================================

-- ============================================================
-- Inventory category seeds for 3D printing items
-- (Only insert if category column + sitename column exist on inventory_items)
-- These are sample rows; adjust sitename as needed.
-- ============================================================
-- NOTE: inventory items with category '3d_filament', '3d_supply', '3d_printed_item'
-- are created via the Inventory module UI. No seed data inserted here.
