-- Migration 007: Add auto_pay and auto_pay_method to inventory_supplier_invoices
-- Required for the auto-pay invoice workflow added in the accounting integration.
-- Run on every DB instance that has the inventory_supplier_invoices table.

ALTER TABLE `inventory_supplier_invoices`
  ADD COLUMN IF NOT EXISTS `auto_pay` tinyint(1) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS `auto_pay_method` varchar(255) DEFAULT NULL;
