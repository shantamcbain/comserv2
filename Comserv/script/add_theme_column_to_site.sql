-- Add theme column to Site table if it doesn't exist
ALTER TABLE Site ADD COLUMN theme VARCHAR(50) DEFAULT 'default';