-- =============================================================================
-- PointSystem Core Schema  (Migration 002)
-- =============================================================================
-- This is the SINGLE AUTHORITATIVE set of financial tables for the application.
-- All modules (Membership, Hosting, Workshops, Services) delegate ALL financial
-- transactions to this schema.  No module owns its own payment tables.
--
-- Supersedes / replaces the following membership-branch tables when merged:
--   internal_currency_accounts      → point_accounts
--   internal_currency_transactions  → point_ledger
--   payment_transactions            → payment_transactions (kept, extended)
--
-- Design principles:
--   • 1 point  = 1 Canadian Dollar (CAD) base value
--   • point_accounts   holds the current balance per user (mutable)
--   • point_ledger     is an append-only audit log of every movement
--   • payment_transactions is a polymorphic ledger for ALL real-money payments
--     covering membership, hosting, workshops, domains, services, coin purchases
--   • currency_rates   stores exchange rates so any amount can be displayed in
--     the user's/site's preferred currency
--   • crypto_transactions tracks blockchain payments (future phase)
--   • All balance mutations MUST run inside a transaction with SELECT ... FOR UPDATE
-- =============================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- point_accounts
-- One row per user. Mutable — updated atomically on every balance change.
-- Replaces: internal_currency_accounts (membership branch)
--           member_points              (earlier pointsystem branch attempt)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `point_accounts` (
    `id`              INT             NOT NULL AUTO_INCREMENT,
    `user_id`         INT             NOT NULL,
    `balance`         DECIMAL(14,4)   NOT NULL DEFAULT 0.0000
                        COMMENT '1.0000 = 1 point = 1 CAD',
    `lifetime_earned` DECIMAL(14,4)   NOT NULL DEFAULT 0.0000
                        COMMENT 'Running total of all credits ever applied',
    `lifetime_spent`  DECIMAL(14,4)   NOT NULL DEFAULT 0.0000
                        COMMENT 'Running total of all debits ever applied',
    `created_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
                        ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_point_accounts_user` (`user_id`),
    CONSTRAINT `fk_pa_user`
        FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Current point balance per member. Always mutated inside a transaction.';

-- -----------------------------------------------------------------------------
-- point_ledger
-- Append-only audit log. Every credit or debit produces one row.
-- NEVER UPDATE or DELETE rows — only INSERT and READ.
-- from_user_id NULL = system/external source (e.g. joining bonus, PayPal top-up).
-- to_user_id   NULL = system/service destination (e.g. membership renewal fee).
-- Replaces: internal_currency_transactions (membership branch)
--           point_transactions             (earlier pointsystem branch attempt)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `point_ledger` (
    `id`               BIGINT          NOT NULL AUTO_INCREMENT,
    `from_user_id`     INT             NULL
                         COMMENT 'Sender — NULL = system/external credit',
    `to_user_id`       INT             NULL
                         COMMENT 'Recipient — NULL = system/service debit',
    `amount`           DECIMAL(14,4)   NOT NULL
                         COMMENT 'Always positive. Direction implied by from/to NULLs.',
    `transaction_type` VARCHAR(50)     NOT NULL
                         COMMENT 'joining_bonus|purchase|spend|transfer|refund|adjustment|subscription|crypto',
    `description`      VARCHAR(500)    NOT NULL DEFAULT '',
    `reference_type`   VARCHAR(100)    NULL
                         COMMENT 'payment_transaction|membership|workshop|hosting|service|manual',
    `reference_id`     BIGINT          NULL
                         COMMENT 'PK of the referenced row in reference_type table',
    `balance_after`    DECIMAL(14,4)   NOT NULL
                         COMMENT 'Snapshot of to_user point_accounts.balance AFTER this row',
    `created_at`       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_pl_from`    (`from_user_id`),
    KEY `idx_pl_to`      (`to_user_id`),
    KEY `idx_pl_type`    (`transaction_type`),
    KEY `idx_pl_ref`     (`reference_type`, `reference_id`),
    KEY `idx_pl_created` (`created_at`),
    CONSTRAINT `fk_pl_from` FOREIGN KEY (`from_user_id`) REFERENCES `users` (`id`),
    CONSTRAINT `fk_pl_to`   FOREIGN KEY (`to_user_id`)   REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Immutable point movement ledger. Append-only — never update or delete.';

-- -----------------------------------------------------------------------------
-- payment_transactions
-- Polymorphic ledger for ALL real-money payments across every module.
-- payable_type identifies the originating module; payable_id is its PK.
-- This table is carried forward from the membership branch design with
-- additions: point_ledger_id link, ip_address, and explicit CAD amount.
-- Owned by PointSystem — Membership, Hosting, Workshops etc. INSERT here via
-- Comserv::Util::PointSystem, never directly.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `payment_transactions` (
    `id`                      BIGINT          NOT NULL AUTO_INCREMENT,
    `user_id`                 INT             NOT NULL,
    `payable_type`            VARCHAR(100)    NOT NULL
                                COMMENT 'membership|hosting|workshop|domain|service|point_purchase',
    `payable_id`              INT             NULL
                                COMMENT 'PK in the payable_type table (polymorphic, no DB FK)',
    `amount`                  DECIMAL(10,2)   NOT NULL,
    `currency`                CHAR(3)         NOT NULL DEFAULT 'CAD',
    `amount_cad`              DECIMAL(10,2)   NOT NULL
                                COMMENT 'Canonical CAD equivalent at time of payment',
    `provider`                VARCHAR(30)     NOT NULL
                                COMMENT 'paypal|crypto|internal|manual|free',
    `provider_transaction_id` VARCHAR(255)    NULL
                                COMMENT 'External provider reference — unique per provider',
    `status`                  VARCHAR(30)     NOT NULL DEFAULT 'pending'
                                COMMENT 'pending|completed|failed|refunded|disputed',
    `description`             VARCHAR(500)    NULL,
    `points_credited`         DECIMAL(14,4)   NOT NULL DEFAULT 0
                                COMMENT 'Points awarded from this payment (0 for non-purchase types)',
    `point_ledger_id`         BIGINT          NULL
                                COMMENT 'FK to point_ledger row that credited the points',
    `metadata`                TEXT            NULL
                                COMMENT 'JSON: provider-specific payload (IPN data, webhook, etc.)',
    `ip_address`              VARCHAR(45)     NULL,
    `created_at`              TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`              TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_provider_txn` (`provider`, `provider_transaction_id`),
    KEY `idx_pmt_user`     (`user_id`),
    KEY `idx_pmt_type`     (`payable_type`),
    KEY `idx_pmt_status`   (`status`),
    KEY `idx_pmt_created`  (`created_at`),
    CONSTRAINT `fk_pmt_user`   FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Polymorphic real-money payment ledger. All modules insert via PointSystem utility.';

-- -----------------------------------------------------------------------------
-- currency_rates
-- Exchange rates vs CAD base.  1 point = 1 CAD.
-- Refreshed periodically by a scheduled job calling an exchange-rate API.
-- Supports displaying prices in any currency on any site.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `currency_rates` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `currency_code` CHAR(3)         NOT NULL COMMENT 'ISO 4217 e.g. USD, EUR, GBP',
    `currency_name` VARCHAR(100)    NOT NULL,
    `rate_to_cad`   DECIMAL(15,6)   NOT NULL
                      COMMENT '1 CAD = rate_to_cad units of this currency. '
                              'e.g. USD: 0.73 means 1 CAD = 0.73 USD',
    `symbol`        VARCHAR(10)     NOT NULL DEFAULT '',
    `is_active`     TINYINT(1)      NOT NULL DEFAULT 1,
    `source`        VARCHAR(100)    NULL COMMENT 'API source that last updated the rate',
    `updated_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
                      ON UPDATE CURRENT_TIMESTAMP,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_currency_code` (`currency_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Exchange rates relative to CAD (base currency for the point system)';

INSERT IGNORE INTO `currency_rates`
    (`currency_code`, `currency_name`, `rate_to_cad`, `symbol`, `is_active`, `source`)
VALUES
    ('CAD', 'Canadian Dollar',      1.000000, 'CA$', 1, 'base'),
    ('USD', 'US Dollar',            0.730000, '$',   1, 'manual'),
    ('EUR', 'Euro',                 0.680000, '€',   1, 'manual'),
    ('GBP', 'British Pound',        0.570000, '£',   1, 'manual'),
    ('AUD', 'Australian Dollar',    1.100000, 'A$',  1, 'manual'),
    ('NZD', 'New Zealand Dollar',   1.190000, 'NZ$', 1, 'manual'),
    ('JPY', 'Japanese Yen',       109.000000, '¥',   1, 'manual'),
    ('CHF', 'Swiss Franc',          0.660000, 'Fr',  1, 'manual'),
    ('MXN', 'Mexican Peso',        12.900000, 'MX$', 1, 'manual'),
    ('BTC', 'Bitcoin',              0.000014, '₿',   1, 'manual'),
    ('ETH', 'Ethereum',             0.000390, 'Ξ',   1, 'manual'),
    ('STEEM', 'Steem',              3.500000, 'STEEM', 0, 'manual');

-- -----------------------------------------------------------------------------
-- point_packages
-- Buyable point bundles shown at checkout (one-time and recurring).
-- PayPal plan IDs for subscriptions are stored here so the PointSystem
-- utility can look up what points to award on each subscription renewal.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `point_packages` (
    `id`             INT             NOT NULL AUTO_INCREMENT,
    `name`           VARCHAR(100)    NOT NULL,
    `description`    TEXT            NULL,
    `points`         DECIMAL(14,4)   NOT NULL COMMENT 'Points credited on purchase',
    `price_cad`      DECIMAL(10,2)   NOT NULL COMMENT 'Canonical price in CAD',
    `package_type`   VARCHAR(20)     NOT NULL DEFAULT 'one_time'
                       COMMENT 'one_time|monthly|annual',
    `paypal_plan_id` VARCHAR(100)    NULL
                       COMMENT 'PayPal subscription plan ID for recurring packages',
    `is_active`      TINYINT(1)      NOT NULL DEFAULT 1,
    `sort_order`     INT             NOT NULL DEFAULT 0,
    `created_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`     TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
                       ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_pkg_active` (`is_active`, `sort_order`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Buyable point bundles. Membership plans reference these for currency_bonus awards.';

INSERT INTO `point_packages`
    (`name`, `description`, `points`, `price_cad`, `package_type`, `is_active`, `sort_order`)
VALUES
    ('Starter Pack',  '100 points – great for getting started',             100,    10.00, 'one_time', 1, 1),
    ('Basic Pack',    '500 points – save 5% vs individual purchase',        500,    47.50, 'one_time', 1, 2),
    ('Value Pack',    '1 000 points – save 10%',                           1000,    90.00, 'one_time', 1, 3),
    ('Power Pack',    '5 000 points – save 15%',                           5000,   425.00, 'one_time', 1, 4),
    ('Monthly Basic', '100 points per month subscription',                  100,     9.00, 'monthly',  1, 5),
    ('Monthly Value', '500 points per month subscription – save 10%',       500,    40.50, 'monthly',  1, 6);

-- -----------------------------------------------------------------------------
-- crypto_transactions
-- Blockchain payment tracking.  Pending until required_confirmations reached,
-- then PointSystem utility credits points and creates a payment_transaction row.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `crypto_transactions` (
    `id`                      BIGINT          NOT NULL AUTO_INCREMENT,
    `user_id`                 INT             NOT NULL,
    `coin`                    VARCHAR(20)     NOT NULL COMMENT 'BTC|ETH|STEEM|...',
    `wallet_address`          VARCHAR(200)    NOT NULL,
    `tx_hash`                 VARCHAR(200)    NULL COMMENT 'Blockchain transaction hash',
    `amount_coin`             DECIMAL(20,8)   NOT NULL,
    `amount_cad`              DECIMAL(10,2)   NOT NULL
                                COMMENT 'CAD equivalent at time of address generation',
    `points_to_credit`        DECIMAL(14,4)   NOT NULL DEFAULT 0,
    `confirmations`           INT             NOT NULL DEFAULT 0,
    `required_confirmations`  INT             NOT NULL DEFAULT 3,
    `status`                  VARCHAR(30)     NOT NULL DEFAULT 'pending'
                                COMMENT 'pending|confirming|completed|failed|expired',
    `payment_transaction_id`  BIGINT          NULL
                                COMMENT 'FK to payment_transactions once confirmed',
    `expires_at`              TIMESTAMP       NULL,
    `created_at`              TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`              TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_ct_user`   (`user_id`),
    KEY `idx_ct_hash`   (`tx_hash`),
    KEY `idx_ct_status` (`status`),
    CONSTRAINT `fk_ct_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Cryptocurrency payment tracking (future phase). Confirmed by blockchain watcher job.';

-- -----------------------------------------------------------------------------
-- site_currency_preference
-- Per-site display currency.  Does not affect point accounting (always CAD-based);
-- only changes how prices and balances are rendered in templates.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `site_currency_preference` (
    `id`            INT             NOT NULL AUTO_INCREMENT,
    `site_id`       INT             NOT NULL,
    `currency_code` CHAR(3)         NOT NULL DEFAULT 'CAD',
    `updated_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP
                      ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_scp_site` (`site_id`),
    CONSTRAINT `fk_scp_site`     FOREIGN KEY (`site_id`)       REFERENCES `sites` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_scp_currency` FOREIGN KEY (`currency_code`) REFERENCES `currency_rates` (`currency_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Which currency a site displays prices in. Accounting always stays in CAD/points.';

SET FOREIGN_KEY_CHECKS = 1;

-- =============================================================================
-- Migration notes for merging with membership-1304 branch
-- =============================================================================
-- When membership-1304 is merged into this branch:
--   1. DROP TABLE internal_currency_accounts   (replaced by point_accounts)
--   2. DROP TABLE internal_currency_transactions (replaced by point_ledger)
--   3. Keep payment_transactions from this file (extended version)
--   4. Membership controllers that currently write to internal_currency_*
--      must be updated to call Comserv::Util::PointSystem instead.
--   5. membership_plans.currency_bonus column is still valid — PointSystem
--      reads it when applying a joining/renewal bonus via apply_plan_bonus().
-- =============================================================================
