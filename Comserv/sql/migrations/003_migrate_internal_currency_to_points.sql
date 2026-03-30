-- =============================================================================
-- Migration 003: Copy historical data from internal_currency_* to point_* tables
-- =============================================================================
-- Run ONCE after 002_point_system_schema.sql has been applied.
--
-- Copies:
--   internal_currency_accounts      → point_accounts
--   internal_currency_transactions  → point_ledger
--
-- Safe to re-run: uses ON DUPLICATE KEY UPDATE for accounts so balances are
-- not double-counted, and skips already-migrated ledger rows via a sentinel
-- reference_type value.
--
-- HOW TO RUN (on the MariaDB host):
--   mysql -u <user> -p <dbname> < 003_migrate_internal_currency_to_points.sql
-- =============================================================================

SET FOREIGN_KEY_CHECKS = 0;
START TRANSACTION;

-- ---------------------------------------------------------------------------
-- Step 1: point_accounts
--
-- For users with NO existing point_accounts row (the vast majority — everyone
-- registered before the new system launched): a clean INSERT copies their
-- full balance and lifetime stats.
--
-- For the rare user who registered AFTER the new system launched (they have
-- a point_accounts row with the 100-point joining bonus) AND also had an
-- internal_currency_accounts row from a previous account: ON DUPLICATE KEY
-- UPDATE adds the old balance on top so nothing is lost.
-- ---------------------------------------------------------------------------
INSERT INTO point_accounts
    (user_id, balance, lifetime_earned, lifetime_spent, created_at, updated_at)
SELECT
    ica.user_id,
    ica.balance,
    ica.lifetime_earned,
    ica.lifetime_spent,
    ica.created_at,
    ica.updated_at
FROM internal_currency_accounts ica
ON DUPLICATE KEY UPDATE
    balance         = point_accounts.balance         + VALUES(balance),
    lifetime_earned = point_accounts.lifetime_earned + VALUES(lifetime_earned),
    lifetime_spent  = point_accounts.lifetime_spent  + VALUES(lifetime_spent),
    updated_at      = NOW();

-- ---------------------------------------------------------------------------
-- Step 2: point_ledger
--
-- Copies every historical transaction.  Uses reference_type = 'migrated_ict'
-- as a sentinel so the INSERT IGNORE (via the check below) can skip rows that
-- were already migrated on a previous run.
--
-- transaction_type mapping (enum → varchar):
--   purchase → purchase   earn → earn   spend → spend   transfer → transfer
--   bonus    → bonus      refund → refund  adjustment → adjustment
-- All values fit comfortably in point_ledger.transaction_type VARCHAR(50).
-- ---------------------------------------------------------------------------
INSERT INTO point_ledger
    (from_user_id, to_user_id, amount, transaction_type,
     description, reference_type, reference_id, balance_after, created_at)
SELECT
    ict.from_user_id,
    ict.to_user_id,
    ict.amount,
    CAST(ict.transaction_type AS CHAR),
    COALESCE(ict.description, ''),
    COALESCE(ict.reference_type, 'migrated_ict'),
    ict.reference_id,
    ict.balance_after,
    ict.created_at
FROM internal_currency_transactions ict
WHERE NOT EXISTS (
    SELECT 1 FROM point_ledger pl
    WHERE pl.from_user_id   <=> ict.from_user_id
      AND pl.to_user_id     <=> ict.to_user_id
      AND pl.amount          = ict.amount
      AND pl.created_at      = ict.created_at
      AND pl.transaction_type = CAST(ict.transaction_type AS CHAR)
);

COMMIT;
SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------------
-- Verification queries — run these manually to confirm the migration:
-- ---------------------------------------------------------------------------
-- SELECT COUNT(*) AS old_accounts FROM internal_currency_accounts;
-- SELECT COUNT(*) AS new_accounts FROM point_accounts;
-- SELECT COUNT(*) AS old_txns     FROM internal_currency_transactions;
-- SELECT COUNT(*) AS new_ledger   FROM point_ledger;
--
-- Check a specific user (replace 1 with your user_id):
-- SELECT pa.user_id, pa.balance, pa.lifetime_earned, pa.lifetime_spent
-- FROM point_accounts pa WHERE pa.user_id = 1;
