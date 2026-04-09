-- Migration: Add project_id, task_id, model columns to ai_conversations
-- Follows Result-file-first policy: columns defined in AiConversation.pm Result file first,
-- this SQL applies the DB-side changes to match.
-- Safe to run multiple times (uses IF NOT EXISTS pattern via column check).

ALTER TABLE ai_conversations
    ADD COLUMN IF NOT EXISTS project_id INT NULL AFTER status,
    ADD COLUMN IF NOT EXISTS task_id    INT NULL AFTER project_id,
    ADD COLUMN IF NOT EXISTS model      VARCHAR(255) NULL AFTER task_id;
