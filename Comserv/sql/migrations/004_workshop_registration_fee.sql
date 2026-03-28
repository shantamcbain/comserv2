-- Migration 004: Add registration_fee column to workshop table
-- =============================================================
-- Allows workshops to charge a point fee on registration.
-- 0.00 means free (no debit).  Non-zero debits via PointSystem.
--
-- HOW TO RUN:
--   mysql -u <user> -p <dbname> < 004_workshop_registration_fee.sql
-- =============================================================

ALTER TABLE workshop
    ADD COLUMN registration_fee DECIMAL(10,2) NOT NULL DEFAULT 0.00
        COMMENT 'Point fee charged on registration; 0 = free';
