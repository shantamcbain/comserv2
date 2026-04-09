-- =============================================================================
-- Log → Points Integration  (Migration 006)
-- =============================================================================
-- When a log entry is closed (status=3/DONE), the developer earns points and
-- the customer is billed points based on the time recorded.
--
-- Changes:
--   log   → add points_processed, point_rate columns
--   todo  → add billable, point_rate columns
-- =============================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- log: track whether a closed entry has already been billed through points
-- point_rate: override rate (pts/hr) for this specific session; NULL = use todo rate
-- -----------------------------------------------------------------------------
ALTER TABLE `log`
    ADD COLUMN IF NOT EXISTS `points_processed` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT '1 once billing/earning has been applied for this closed session',
    ADD COLUMN IF NOT EXISTS `point_rate` DECIMAL(10,4) NULL
        COMMENT 'Override pts/hr for this session. NULL = inherit from todo or system default';

-- If the column already exists without DEFAULT 0, fix it:
ALTER TABLE `log`
    MODIFY COLUMN `points_processed` TINYINT(1) NOT NULL DEFAULT 0
        COMMENT '1 once billing/earning has been applied for this closed session';

-- -----------------------------------------------------------------------------
-- todo: billing settings per task
-- billable: 0 = internal/non-billable, 1 = charge customer when log is closed
-- point_rate: pts/hr charged to the customer (and paid to the developer)
--             NULL = use the system default (DEFAULT_POINT_RATE in PointSystem.pm)
-- -----------------------------------------------------------------------------
ALTER TABLE `todo`
    ADD COLUMN IF NOT EXISTS `billable` TINYINT(1) NOT NULL DEFAULT 1
        COMMENT '1 = customer is billed via points when a log entry on this todo is closed',
    ADD COLUMN IF NOT EXISTS `point_rate` DECIMAL(10,4) NULL
        COMMENT 'pts/hr for billing. NULL = system default (60 pts/hr = 60 CAD/hr)';

SET FOREIGN_KEY_CHECKS = 1;
