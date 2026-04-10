-- Comserv Accounting Foundation — modeled on SQL-Ledger / LedgerSMB
--
-- Key design decisions drawn from SQL-Ledger:
--   1. Chart of Accounts (coa_accounts) with category A/L/Q/I/E
--   2. Every inventory item links to 3-4 COA accounts (stock/income/COGS/returns)
--   3. General Ledger journal: gl_entries (header) + gl_entry_lines (double-entry)
--   4. Point System and inventory transactions both bridge to GL for full accounting
--
-- LedgerSMB equivalents:
--   coa_accounts         ≈  account
--   coa_account_headings ≈  account_heading
--   gl_entries           ≈  journal_entry
--   gl_entry_lines       ≈  journal_line / acc_trans
--   inventory_items cols ≈  parts.inventory_accno_id / income_accno_id / expense_accno_id
--
-- Run after: inventory_tables.sql
-- ============================================================================

SET FOREIGN_KEY_CHECKS = 1;

-- ============================================================================
-- CHART OF ACCOUNTS — COA headings (groups/sections)
-- ============================================================================

CREATE TABLE IF NOT EXISTS `coa_account_headings` (
  `id`          INT NOT NULL AUTO_INCREMENT,
  `accno`       VARCHAR(30) NOT NULL          COMMENT 'Account number/code e.g. 1000',
  `parent_id`   INT DEFAULT NULL              COMMENT 'Parent heading for nesting',
  `description` VARCHAR(255) NOT NULL,
  `category`    CHAR(1) NOT NULL
                COMMENT 'A=Asset L=Liability Q=Equity I=Income E=Expense',
  `sitename`    VARCHAR(100) DEFAULT NULL     COMMENT 'NULL = system-wide heading',
  `sort_order`  INT NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_heading_accno` (`accno`),
  KEY `idx_heading_parent` (`parent_id`),
  KEY `idx_heading_category` (`category`),
  CONSTRAINT `fk_coa_heading_parent`
    FOREIGN KEY (`parent_id`) REFERENCES `coa_account_headings` (`id`)
    ON DELETE SET NULL,
  CONSTRAINT `chk_heading_category`
    CHECK (`category` IN ('A','L','Q','I','E'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- CHART OF ACCOUNTS — individual accounts
-- ============================================================================

CREATE TABLE IF NOT EXISTS `coa_accounts` (
  `id`          INT NOT NULL AUTO_INCREMENT,
  `accno`       VARCHAR(30) NOT NULL          COMMENT 'Account number e.g. 1200, 5000',
  `description` VARCHAR(255) NOT NULL,
  `category`    CHAR(1) NOT NULL
                COMMENT 'A=Asset L=Liability Q=Equity I=Income E=Expense',
  `heading_id`  INT DEFAULT NULL              COMMENT 'FK → coa_account_headings',
  `is_contra`   TINYINT(1) NOT NULL DEFAULT 0 COMMENT 'Contra account (e.g. accumulated depreciation)',
  `is_tax`      TINYINT(1) NOT NULL DEFAULT 0,
  `obsolete`    TINYINT(1) NOT NULL DEFAULT 0,
  `sitename`    VARCHAR(100) DEFAULT NULL     COMMENT 'NULL = applies to all sites',
  `notes`       TEXT,
  `created_at`  DATETIME DEFAULT CURRENT_TIMESTAMP,
  `updated_at`  DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_coa_accno` (`accno`),
  KEY `idx_coa_category` (`category`),
  KEY `idx_coa_heading` (`heading_id`),
  KEY `idx_coa_obsolete` (`obsolete`),
  CONSTRAINT `fk_coa_heading`
    FOREIGN KEY (`heading_id`) REFERENCES `coa_account_headings` (`id`)
    ON DELETE SET NULL,
  CONSTRAINT `chk_coa_category`
    CHECK (`category` IN ('A','L','Q','I','E'))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- LINK INVENTORY ITEMS TO COA ACCOUNTS
-- (SQL-Ledger: parts.inventory_accno_id / income_accno_id / expense_accno_id)
-- ============================================================================

ALTER TABLE `inventory_items`
  ADD COLUMN IF NOT EXISTS `inventory_accno_id` INT DEFAULT NULL
    COMMENT 'COA account for stock value (Asset — e.g. 1300 Inventory Asset)'
    AFTER `is_assemblable`,
  ADD COLUMN IF NOT EXISTS `income_accno_id`    INT DEFAULT NULL
    COMMENT 'COA account when item is sold (Income — e.g. 4000 Sales Revenue)'
    AFTER `inventory_accno_id`,
  ADD COLUMN IF NOT EXISTS `expense_accno_id`   INT DEFAULT NULL
    COMMENT 'COA account for COGS/expense (Expense — e.g. 5000 Cost of Goods Sold)'
    AFTER `income_accno_id`,
  ADD COLUMN IF NOT EXISTS `returns_accno_id`   INT DEFAULT NULL
    COMMENT 'COA account for returns/refunds (Income contra — e.g. 4100 Sales Returns)'
    AFTER `expense_accno_id`,
  ADD KEY IF NOT EXISTS `idx_inv_item_inv_accno`  (`inventory_accno_id`),
  ADD KEY IF NOT EXISTS `idx_inv_item_inc_accno`  (`income_accno_id`),
  ADD KEY IF NOT EXISTS `idx_inv_item_exp_accno`  (`expense_accno_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_inv_item_inventory_accno`
    FOREIGN KEY (`inventory_accno_id`) REFERENCES `coa_accounts` (`id`) ON DELETE SET NULL,
  ADD CONSTRAINT IF NOT EXISTS `fk_inv_item_income_accno`
    FOREIGN KEY (`income_accno_id`)    REFERENCES `coa_accounts` (`id`) ON DELETE SET NULL,
  ADD CONSTRAINT IF NOT EXISTS `fk_inv_item_expense_accno`
    FOREIGN KEY (`expense_accno_id`)   REFERENCES `coa_accounts` (`id`) ON DELETE SET NULL,
  ADD CONSTRAINT IF NOT EXISTS `fk_inv_item_returns_accno`
    FOREIGN KEY (`returns_accno_id`)   REFERENCES `coa_accounts` (`id`) ON DELETE SET NULL;

-- ============================================================================
-- GENERAL LEDGER — journal entry headers
-- (SQL-Ledger: journal_entry)
-- ============================================================================

CREATE TABLE IF NOT EXISTS `gl_entries` (
  `id`          INT NOT NULL AUTO_INCREMENT,
  `reference`   VARCHAR(100) NOT NULL         COMMENT 'Invoice/journal number',
  `description` TEXT,
  `entry_type`  VARCHAR(30) NOT NULL DEFAULT 'general'
                COMMENT 'general | inventory | point | sale | purchase | adjustment',
  `post_date`   DATE NOT NULL,
  `approved`    TINYINT(1) NOT NULL DEFAULT 0,
  `is_template` TINYINT(1) NOT NULL DEFAULT 0,
  `currency`    CHAR(3) NOT NULL DEFAULT 'CAD',
  `sitename`    VARCHAR(100) NOT NULL,
  `entered_by`  INT DEFAULT NULL              COMMENT 'FK → users.id',
  `approved_by` INT DEFAULT NULL              COMMENT 'FK → users.id',
  `created_at`  DATETIME DEFAULT CURRENT_TIMESTAMP,
  `updated_at`  DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_gl_reference` (`reference`, `entry_type`),
  KEY `idx_gl_post_date` (`post_date`),
  KEY `idx_gl_entry_type` (`entry_type`),
  KEY `idx_gl_sitename` (`sitename`),
  KEY `idx_gl_approved` (`approved`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- GENERAL LEDGER — journal entry lines (double-entry)
-- (SQL-Ledger: journal_line / acc_trans)
-- Each gl_entry must have lines that sum to zero (debits = credits).
-- ============================================================================

CREATE TABLE IF NOT EXISTS `gl_entry_lines` (
  `id`            INT NOT NULL AUTO_INCREMENT,
  `gl_entry_id`   INT NOT NULL                COMMENT 'FK → gl_entries',
  `account_id`    INT NOT NULL                COMMENT 'FK → coa_accounts',
  `amount`        DECIMAL(14,4) NOT NULL
                  COMMENT 'Positive=debit, Negative=credit (SQL-Ledger convention)',
  `memo`          VARCHAR(500),
  `cleared`       TINYINT(1) NOT NULL DEFAULT 0,
  `sort_order`    INT NOT NULL DEFAULT 0,
  `created_at`    DATETIME DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_gl_line_entry` (`gl_entry_id`),
  KEY `idx_gl_line_account` (`account_id`),
  KEY `idx_gl_line_cleared` (`cleared`),
  CONSTRAINT `fk_gl_line_entry`
    FOREIGN KEY (`gl_entry_id`) REFERENCES `gl_entries` (`id`)
    ON DELETE CASCADE,
  CONSTRAINT `fk_gl_line_account`
    FOREIGN KEY (`account_id`) REFERENCES `coa_accounts` (`id`)
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================
-- BRIDGE: link inventory_transactions and point_ledger to GL entries
-- When a stock movement or point transaction is posted, it generates a GL entry.
-- ============================================================================

ALTER TABLE `inventory_transactions`
  ADD COLUMN IF NOT EXISTS `gl_entry_id` INT DEFAULT NULL
    COMMENT 'FK → gl_entries — the double-entry journal record for this transaction'
    AFTER `todo_id`,
  ADD KEY IF NOT EXISTS `idx_inv_tx_gl_entry` (`gl_entry_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_inv_tx_gl_entry`
    FOREIGN KEY (`gl_entry_id`) REFERENCES `gl_entries` (`id`)
    ON DELETE SET NULL;

ALTER TABLE `point_ledger`
  ADD COLUMN IF NOT EXISTS `gl_entry_id` INT DEFAULT NULL
    COMMENT 'FK → gl_entries — maps this point transaction to a real GL entry'
    AFTER `balance_after`,
  ADD KEY IF NOT EXISTS `idx_point_ledger_gl` (`gl_entry_id`),
  ADD CONSTRAINT IF NOT EXISTS `fk_point_ledger_gl`
    FOREIGN KEY (`gl_entry_id`) REFERENCES `gl_entries` (`id`)
    ON DELETE SET NULL;

-- ============================================================================
-- SEED: Standard Chart of Accounts headings (Canadian small business)
-- Adapt account numbers / descriptions to your chart of accounts.
-- ============================================================================

INSERT IGNORE INTO `coa_account_headings` (`accno`, `description`, `category`, `sort_order`) VALUES
  ('1000', 'Current Assets',            'A', 10),
  ('1200', 'Inventory Assets',          'A', 20),
  ('1500', 'Fixed Assets',              'A', 30),
  ('2000', 'Current Liabilities',       'L', 10),
  ('2500', 'Long-Term Liabilities',     'L', 20),
  ('3000', 'Equity',                    'Q', 10),
  ('4000', 'Revenue',                   'I', 10),
  ('4100', 'Revenue Adjustments',       'I', 20),
  ('5000', 'Cost of Goods Sold',        'E', 10),
  ('6000', 'Operating Expenses',        'E', 20),
  ('7000', 'Point System Accounts',     'A', 40);

-- Standard COA accounts (a minimal but functional set)
INSERT IGNORE INTO `coa_accounts` (`accno`, `description`, `category`, `heading_id`) VALUES
  ('1010', 'Bank — Chequing',                 'A', (SELECT id FROM coa_account_headings WHERE accno='1000')),
  ('1020', 'Petty Cash',                      'A', (SELECT id FROM coa_account_headings WHERE accno='1000')),
  ('1100', 'Accounts Receivable',             'A', (SELECT id FROM coa_account_headings WHERE accno='1000')),
  ('1200', 'Inventory — Raw Materials',       'A', (SELECT id FROM coa_account_headings WHERE accno='1200')),
  ('1210', 'Inventory — Work In Progress',    'A', (SELECT id FROM coa_account_headings WHERE accno='1200')),
  ('1220', 'Inventory — Finished Goods',      'A', (SELECT id FROM coa_account_headings WHERE accno='1200')),
  ('1230', 'Inventory — Apiary Equipment',    'A', (SELECT id FROM coa_account_headings WHERE accno='1200')),
  ('1240', 'Inventory — Garden/Harvest',      'A', (SELECT id FROM coa_account_headings WHERE accno='1200')),
  ('1250', 'Inventory — 3D Print Materials',  'A', (SELECT id FROM coa_account_headings WHERE accno='1200')),
  ('1500', 'Equipment & Machinery',           'A', (SELECT id FROM coa_account_headings WHERE accno='1500')),
  ('2100', 'Accounts Payable',                'L', (SELECT id FROM coa_account_headings WHERE accno='2000')),
  ('2200', 'HST/GST Payable',                 'L', (SELECT id FROM coa_account_headings WHERE accno='2000')),
  ('3100', "Owner's Equity",                  'Q', (SELECT id FROM coa_account_headings WHERE accno='3000')),
  ('3200', 'Retained Earnings',               'Q', (SELECT id FROM coa_account_headings WHERE accno='3000')),
  ('4000', 'Sales Revenue — General',         'I', (SELECT id FROM coa_account_headings WHERE accno='4000')),
  ('4010', 'Sales Revenue — Honey/Apiary',    'I', (SELECT id FROM coa_account_headings WHERE accno='4000')),
  ('4020', 'Sales Revenue — Garden Produce',  'I', (SELECT id FROM coa_account_headings WHERE accno='4000')),
  ('4030', 'Sales Revenue — Crafts/Art',      'I', (SELECT id FROM coa_account_headings WHERE accno='4000')),
  ('4040', 'Sales Revenue — 3D Printing',     'I', (SELECT id FROM coa_account_headings WHERE accno='4000')),
  ('4100', 'Sales Returns & Allowances',      'I', (SELECT id FROM coa_account_headings WHERE accno='4100')),
  ('5000', 'Cost of Goods Sold — General',    'E', (SELECT id FROM coa_account_headings WHERE accno='5000')),
  ('5010', 'COGS — Apiary Supplies',          'E', (SELECT id FROM coa_account_headings WHERE accno='5000')),
  ('5020', 'COGS — Garden/Growing Inputs',    'E', (SELECT id FROM coa_account_headings WHERE accno='5000')),
  ('5030', 'COGS — Manufacturing/Crafting',   'E', (SELECT id FROM coa_account_headings WHERE accno='5000')),
  ('5040', 'COGS — 3D Print Filament',        'E', (SELECT id FROM coa_account_headings WHERE accno='5000')),
  ('6100', 'Labour — General',                'E', (SELECT id FROM coa_account_headings WHERE accno='6000')),
  ('6200', 'Equipment Maintenance',           'E', (SELECT id FROM coa_account_headings WHERE accno='6000')),
  ('7000', 'Point System — User Balances',    'A', (SELECT id FROM coa_account_headings WHERE accno='7000')),
  ('7010', 'Point System — Earned Points',    'I', (SELECT id FROM coa_account_headings WHERE accno='7000')),
  ('7020', 'Point System — Redeemed Points',  'E', (SELECT id FROM coa_account_headings WHERE accno='7000'));
