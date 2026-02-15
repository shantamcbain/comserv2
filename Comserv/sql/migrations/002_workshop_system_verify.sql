-- Verification Script for Migration 002: Workshop System
-- Date: 2026-02-14
-- Run this script after executing 002_workshop_system.sql

-- ============================================================================
-- PART 1: VERIFY TABLE EXISTENCE
-- ============================================================================

-- Check all workshop-related tables exist
SHOW TABLES LIKE 'workshop%';
-- Expected: workshop, workshop_content, workshop_emails, workshop_roles

-- Check participant table exists
SHOW TABLES LIKE 'participant';
-- Expected: participant

-- Check site_workshop junction table exists
SHOW TABLES LIKE 'site_workshop';
-- Expected: site_workshop

-- ============================================================================
-- PART 2: VERIFY WORKSHOP TABLE EXTENSIONS
-- ============================================================================

-- Show all columns in workshop table
DESCRIBE workshop;
-- Expected new columns: status, created_by, created_at, updated_at, registration_deadline, site_id

-- Show indexes on workshop table
SHOW INDEX FROM workshop;
-- Expected indexes: idx_workshop_status, idx_workshop_created_by, idx_workshop_site, idx_workshop_date

-- Verify workshop status column enum values
SELECT COLUMN_TYPE 
FROM INFORMATION_SCHEMA.COLUMNS 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'workshop' 
  AND COLUMN_NAME = 'status';
-- Expected: enum('draft','published','registration_closed','in_progress','completed','cancelled')

-- ============================================================================
-- PART 3: VERIFY PARTICIPANT TABLE EXTENSIONS
-- ============================================================================

-- Show all columns in participant table
DESCRIBE participant;
-- Expected new columns: user_id, email, site_affiliation, registered_at, status

-- Show indexes on participant table
SHOW INDEX FROM participant;
-- Expected indexes: idx_participant_workshop, idx_participant_user, idx_participant_status

-- Verify participant status column enum values
SELECT COLUMN_TYPE 
FROM INFORMATION_SCHEMA.COLUMNS 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'participant' 
  AND COLUMN_NAME = 'status';
-- Expected: enum('registered','waitlist','attended','cancelled')

-- ============================================================================
-- PART 4: VERIFY NEW TABLE STRUCTURES
-- ============================================================================

-- Verify workshop_content table structure
DESCRIBE workshop_content;
SHOW INDEX FROM workshop_content;
-- Expected columns: id, workshop_id, content_type, title, content, file_id, sort_order, created_at, updated_at
-- Expected indexes: idx_content_workshop, idx_content_sort
-- Expected FKs: workshop_id -> workshop(id), file_id -> files(id)

-- Verify workshop_emails table structure
DESCRIBE workshop_emails;
SHOW INDEX FROM workshop_emails;
-- Expected columns: id, workshop_id, sent_by, subject, body, sent_at, recipient_count, status
-- Expected indexes: idx_email_workshop, idx_email_sent_at
-- Expected FKs: workshop_id -> workshop(id), sent_by -> users(id)

-- Verify workshop_roles table structure
DESCRIBE workshop_roles;
SHOW INDEX FROM workshop_roles;
-- Expected columns: id, user_id, workshop_id, role, site_id, granted_by, granted_at
-- Expected indexes: idx_role_user, idx_role_workshop, idx_role_site
-- Expected unique key: user_workshop_role (user_id, workshop_id)
-- Expected FKs: user_id -> users(id), workshop_id -> workshop(id), granted_by -> users(id)

-- Verify site_workshop table structure
DESCRIBE site_workshop;
SHOW INDEX FROM site_workshop;
-- Expected columns: id, site_id, workshop_id, created_at
-- Expected indexes: idx_site_workshop_site, idx_site_workshop_workshop
-- Expected unique key: site_workshop_unique (site_id, workshop_id)
-- Expected FK: workshop_id -> workshop(id)

-- ============================================================================
-- PART 5: VERIFY FOREIGN KEY CONSTRAINTS
-- ============================================================================

-- Check foreign keys on workshop_content
SELECT 
    CONSTRAINT_NAME, 
    COLUMN_NAME, 
    REFERENCED_TABLE_NAME, 
    REFERENCED_COLUMN_NAME 
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'workshop_content' 
  AND REFERENCED_TABLE_NAME IS NOT NULL;

-- Check foreign keys on workshop_emails
SELECT 
    CONSTRAINT_NAME, 
    COLUMN_NAME, 
    REFERENCED_TABLE_NAME, 
    REFERENCED_COLUMN_NAME 
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'workshop_emails' 
  AND REFERENCED_TABLE_NAME IS NOT NULL;

-- Check foreign keys on workshop_roles
SELECT 
    CONSTRAINT_NAME, 
    COLUMN_NAME, 
    REFERENCED_TABLE_NAME, 
    REFERENCED_COLUMN_NAME 
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'workshop_roles' 
  AND REFERENCED_TABLE_NAME IS NOT NULL;

-- Check foreign keys on site_workshop
SELECT 
    CONSTRAINT_NAME, 
    COLUMN_NAME, 
    REFERENCED_TABLE_NAME, 
    REFERENCED_COLUMN_NAME 
FROM INFORMATION_SCHEMA.KEY_COLUMN_USAGE 
WHERE TABLE_SCHEMA = DATABASE() 
  AND TABLE_NAME = 'site_workshop' 
  AND REFERENCED_TABLE_NAME IS NOT NULL;

-- ============================================================================
-- PART 6: VERIFY DATA INTEGRITY
-- ============================================================================

-- Count existing workshop records (should be preserved)
SELECT COUNT(*) as workshop_count FROM workshop;

-- Count existing participant records (should be preserved)
SELECT COUNT(*) as participant_count FROM participant;

-- Sample workshop record to verify existing data intact
SELECT id, title, sitename, date, max_participants, status, created_at 
FROM workshop 
LIMIT 1;

-- Sample participant record to verify existing data intact
SELECT id, workshop_id, name, email, status, registered_at 
FROM participant 
LIMIT 1;

-- ============================================================================
-- MIGRATION VERIFICATION COMPLETE
-- ============================================================================
-- If all queries above return expected results, migration is successful.
-- Next step: Update DBIx::Class Result classes (Phase 1B)
