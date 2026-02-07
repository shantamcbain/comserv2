-- Migration: Add allowed_roles column to todo table
-- Date: 2026-02-07
-- Description: Add JSON column for role-based access control to todos

ALTER TABLE todo 
ADD COLUMN allowed_roles JSON NULL AFTER time_of_day;
