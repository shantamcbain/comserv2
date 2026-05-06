-- Migration: 20260411_3d_inventory_integration.sql
-- Purpose: Extend inventory_items with selling_price and link print jobs to filament inventory
-- Author: Shanta / AI Assistant
-- Date: 2026-04-11

-- ============================================================
-- Add selling_price to inventory_items
-- Allows 3d_printed_item and filament items to have a retail price
-- separate from unit_cost (the cost to us)
-- ============================================================
ALTER TABLE inventory_items
    ADD COLUMN IF NOT EXISTS selling_price DECIMAL(10,2) DEFAULT NULL
        COMMENT 'Retail/selling price charged to customers';

-- ============================================================
-- Add filament tracking to print jobs
-- filament_item_id links to the InventoryItem (3d_filament)
-- filament_quantity is the amount reserved/consumed
-- inventory_reserved tracks whether reservation was recorded
-- ============================================================
ALTER TABLE printing_3d_jobs
    ADD COLUMN IF NOT EXISTS filament_item_id  INT          DEFAULT NULL
        COMMENT 'FK to inventory_items.id for the filament used',
    ADD COLUMN IF NOT EXISTS filament_quantity  DECIMAL(10,3) DEFAULT 1.000
        COMMENT 'Quantity of filament units reserved/consumed',
    ADD COLUMN IF NOT EXISTS inventory_reserved TINYINT(1)   DEFAULT 0
        COMMENT '1 when filament reservation has been recorded in inventory_transactions';

-- ============================================================
-- Add "reserve" and "reserve_release" to transaction type docs
-- (No schema change needed — transaction_type is varchar)
-- Values used by 3D module:
--   reserve         — filament reserved when print job placed
--   reserve_release — reservation reversed when job cancelled
--   issue           — filament consumed when job completed / item sold to customer
-- ============================================================
