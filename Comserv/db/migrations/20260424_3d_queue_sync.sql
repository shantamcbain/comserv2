-- Migration: 20260424_3d_queue_sync.sql
-- Purpose: Add filament colour/type to inventory_items so filament spools
--          can be matched automatically when creating print jobs from inventory
--          restock needs or consignment orders.
--          Add source tracking and consignment link to print jobs.
-- Author: AI Assistant
-- Date: 2026-04-24

-- ============================================================
-- inventory_items: filament / printed-item attributes
-- ============================================================
ALTER TABLE inventory_items
    ADD COLUMN IF NOT EXISTS filament_color VARCHAR(100) DEFAULT NULL
        COMMENT 'For 3d_filament: colour of spool. For 3d_printed_item: required filament colour.',
    ADD COLUMN IF NOT EXISTS filament_type  VARCHAR(100) DEFAULT NULL
        COMMENT 'For 3d_filament: material type (PLA/PETG/ABS…). For 3d_printed_item: required filament type.',
    ADD COLUMN IF NOT EXISTS requires_printing TINYINT(1) DEFAULT 0
        COMMENT '1 = item is printed on demand (no standing stock maintained)';

-- ============================================================
-- printing_3d_jobs: source tracking + consignment link
-- ============================================================
ALTER TABLE printing_3d_jobs
    ADD COLUMN IF NOT EXISTS source_type        VARCHAR(20)  DEFAULT 'manual'
        COMMENT 'manual | restock | consignment',
    ADD COLUMN IF NOT EXISTS source_item_id     INT          DEFAULT NULL
        COMMENT 'FK to inventory_items.id — the printed item triggering this job',
    ADD COLUMN IF NOT EXISTS consignment_id     INT          DEFAULT NULL
        COMMENT 'FK to inventory_consignments.id',
    ADD COLUMN IF NOT EXISTS consignment_line_id INT         DEFAULT NULL
        COMMENT 'FK to inventory_consignment_lines.id',
    ADD COLUMN IF NOT EXISTS item_name          VARCHAR(255) DEFAULT NULL
        COMMENT 'Name of the printed item (denormalised for display when no model record)';
