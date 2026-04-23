-- Migration: 20260423_3d_printer_cost_integration.sql
-- Purpose: Link 3D printers to inventory asset records so all costing flows
--          through the inventory/accounting system.
-- Author: AI Assistant
-- Date: 2026-04-23

-- ============================================================
-- Link each printer to an inventory_items asset record.
-- The inventory_items record (category='3d_printer') holds
-- purchase_date, unit_cost (purchase price), etc.
-- The companion inventory_equipment record holds
-- depreciation_per_hour and wattage.
-- ============================================================
ALTER TABLE printing_3d_printers
    ADD COLUMN IF NOT EXISTS inventory_item_id INT DEFAULT NULL
        COMMENT 'FK to inventory_items.id — the printer as an equipment asset';

-- ============================================================
-- Job cost columns — populated on job completion by the
-- controller after reading inventory/equipment rates.
-- ============================================================
ALTER TABLE printing_3d_jobs
    ADD COLUMN IF NOT EXISTS print_hours     DECIMAL(6,2)  DEFAULT NULL
        COMMENT 'Actual hours taken to print (entered by admin on completion)',
    ADD COLUMN IF NOT EXISTS filament_cost   DECIMAL(10,2) DEFAULT NULL
        COMMENT 'filament_quantity * filament.unit_cost at time of completion',
    ADD COLUMN IF NOT EXISTS printer_cost    DECIMAL(10,2) DEFAULT NULL
        COMMENT 'print_hours * equipment.depreciation_per_hour at time of completion',
    ADD COLUMN IF NOT EXISTS electricity_cost DECIMAL(10,2) DEFAULT NULL
        COMMENT 'print_hours * wattage * kwh_rate / 1000 (optional)',
    ADD COLUMN IF NOT EXISTS total_cost      DECIMAL(10,2) DEFAULT NULL
        COMMENT 'filament_cost + printer_cost + electricity_cost';
