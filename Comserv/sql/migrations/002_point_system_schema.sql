-- PointSystem Database Schema Migration
-- Creates all tables required for the internal point-based payment system.
--
-- Design principles:
--   - 1 point = 1 Canadian Dollar (CAD) base value
--   - Points stored as integers (whole points only)
--   - All monetary amounts stored as DECIMAL(15,4) for precision
--   - Multi-currency via exchange_rates table
--   - Immutable ledger: transactions are never deleted, only reversed
--   - PayPal integration via paypal_transactions table
--   - Future crypto support via crypto_transactions table

-- ============================================================
-- member_points: current point balance per user
-- ============================================================
CREATE TABLE IF NOT EXISTS `member_points` (
    `id`              INT             NOT NULL AUTO_INCREMENT,
    `user_id`         INT             NOT NULL,
    `balance`         BIGINT          NOT NULL DEFAULT 0 COMMENT 'Current point balance (integer, 1 pt = 1 CAD)',
    `lifetime_earned` BIGINT          NOT NULL DEFAULT 0 COMMENT 'Total points ever earned',
    `lifetime_spent`  BIGINT          NOT NULL DEFAULT 0 COMMENT 'Total points ever spent',
    `created_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_member_points_user` (`user_id`),
    CONSTRAINT `fk_member_points_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Current point balance for each member';

-- ============================================================
-- point_transactions: immutable ledger of all point movements
-- ============================================================
CREATE TABLE IF NOT EXISTS `point_transactions` (
    `id`              BIGINT          NOT NULL AUTO_INCREMENT,
    `user_id`         INT             NOT NULL,
    `amount`          BIGINT          NOT NULL COMMENT 'Positive = credit, Negative = debit',
    `balance_after`   BIGINT          NOT NULL COMMENT 'Balance after this transaction',
    `type`            VARCHAR(50)     NOT NULL COMMENT 'joining_bonus|purchase|spend|refund|adjustment|subscription|crypto',
    `status`          VARCHAR(30)     NOT NULL DEFAULT 'completed' COMMENT 'pending|completed|failed|reversed',
    `reference_type`  VARCHAR(50)     NULL COMMENT 'paypal_transaction|crypto_transaction|service_payment|manual',
    `reference_id`    BIGINT          NULL COMMENT 'FK to the relevant reference table row',
    `description`     VARCHAR(500)    NOT NULL DEFAULT '',
    `created_by`      INT             NULL COMMENT 'Admin user ID if manual adjustment',
    `created_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_pt_user` (`user_id`),
    KEY `idx_pt_type` (`type`),
    KEY `idx_pt_status` (`status`),
    KEY `idx_pt_created` (`created_at`),
    CONSTRAINT `fk_pt_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Immutable ledger of all point movements';

-- ============================================================
-- currency_rates: exchange rates relative to CAD base
-- ============================================================
CREATE TABLE IF NOT EXISTS `currency_rates` (
    `id`              INT             NOT NULL AUTO_INCREMENT,
    `currency_code`   CHAR(3)         NOT NULL COMMENT 'ISO 4217 code e.g. USD, EUR, GBP',
    `currency_name`   VARCHAR(100)    NOT NULL,
    `rate_to_cad`     DECIMAL(15,6)   NOT NULL COMMENT 'How many CAD equal 1 unit of this currency',
    `symbol`          VARCHAR(10)     NOT NULL DEFAULT '',
    `is_active`       TINYINT(1)      NOT NULL DEFAULT 1,
    `source`          VARCHAR(100)    NULL COMMENT 'API source that provided the rate',
    `updated_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    `created_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_currency_code` (`currency_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Exchange rates relative to CAD (base currency for points)';

-- Seed common currencies
INSERT IGNORE INTO `currency_rates` (`currency_code`, `currency_name`, `rate_to_cad`, `symbol`, `is_active`, `source`) VALUES
('CAD', 'Canadian Dollar',     1.000000, 'CA$', 1, 'base'),
('USD', 'US Dollar',           0.730000, '$',   1, 'manual'),
('EUR', 'Euro',                0.680000, '€',   1, 'manual'),
('GBP', 'British Pound',       0.570000, '£',   1, 'manual'),
('AUD', 'Australian Dollar',   1.100000, 'A$',  1, 'manual'),
('NZD', 'New Zealand Dollar',  1.190000, 'NZ$', 1, 'manual'),
('JPY', 'Japanese Yen',       109.00000, '¥',   1, 'manual'),
('CHF', 'Swiss Franc',         0.660000, 'Fr',  1, 'manual'),
('MXN', 'Mexican Peso',       12.900000, 'MX$', 1, 'manual'),
('BTC', 'Bitcoin',             0.000014, '₿',   1, 'manual'),
('ETH', 'Ethereum',            0.000390, 'Ξ',   1, 'manual');

-- ============================================================
-- point_packages: buyable point bundles for PayPal checkout
-- ============================================================
CREATE TABLE IF NOT EXISTS `point_packages` (
    `id`              INT             NOT NULL AUTO_INCREMENT,
    `name`            VARCHAR(100)    NOT NULL,
    `description`     TEXT            NULL,
    `points`          BIGINT          NOT NULL COMMENT 'Points granted on purchase',
    `price_cad`       DECIMAL(10,2)   NOT NULL COMMENT 'Price in CAD',
    `package_type`    VARCHAR(20)     NOT NULL DEFAULT 'one_time' COMMENT 'one_time|monthly|annual',
    `paypal_plan_id`  VARCHAR(100)    NULL COMMENT 'PayPal subscription plan ID (for recurring)',
    `is_active`       TINYINT(1)      NOT NULL DEFAULT 1,
    `sort_order`      INT             NOT NULL DEFAULT 0,
    `created_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_packages_active` (`is_active`, `sort_order`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Point packages available for purchase via PayPal';

-- Seed starter packages
INSERT INTO `point_packages` (`name`, `description`, `points`, `price_cad`, `package_type`, `is_active`, `sort_order`) VALUES
('Starter Pack',    '100 points - great for getting started',                         100,    10.00,  'one_time', 1, 1),
('Basic Pack',      '500 points - save 5% over individual points',                    500,    47.50,  'one_time', 1, 2),
('Value Pack',      '1000 points - save 10% over individual points',                  1000,   90.00,  'one_time', 1, 3),
('Power Pack',      '5000 points - save 15% over individual points',                  5000,  425.00,  'one_time', 1, 4),
('Monthly Basic',   '100 points per month subscription',                               100,    9.00,  'monthly',  1, 5),
('Monthly Value',   '500 points per month subscription - save 10%',                    500,   40.50,  'monthly',  1, 6);

-- ============================================================
-- paypal_transactions: PayPal payment records
-- ============================================================
CREATE TABLE IF NOT EXISTS `paypal_transactions` (
    `id`                  BIGINT          NOT NULL AUTO_INCREMENT,
    `user_id`             INT             NOT NULL,
    `package_id`          INT             NULL,
    `paypal_order_id`     VARCHAR(100)    NULL COMMENT 'PayPal order/transaction ID',
    `paypal_subscription_id` VARCHAR(100) NULL COMMENT 'PayPal subscription ID (recurring)',
    `paypal_payer_id`     VARCHAR(100)    NULL,
    `paypal_payer_email`  VARCHAR(255)    NULL,
    `amount`              DECIMAL(10,2)   NOT NULL COMMENT 'Amount charged',
    `currency`            CHAR(3)         NOT NULL DEFAULT 'CAD',
    `amount_cad`          DECIMAL(10,2)   NOT NULL COMMENT 'Equivalent amount in CAD',
    `points_credited`     BIGINT          NOT NULL DEFAULT 0,
    `payment_type`        VARCHAR(20)     NOT NULL DEFAULT 'one_time' COMMENT 'one_time|subscription',
    `status`              VARCHAR(30)     NOT NULL DEFAULT 'pending' COMMENT 'pending|completed|failed|refunded|cancelled',
    `paypal_status`       VARCHAR(50)     NULL COMMENT 'Raw PayPal status string',
    `ipn_verified`        TINYINT(1)      NOT NULL DEFAULT 0,
    `raw_response`        TEXT            NULL COMMENT 'Raw PayPal API response JSON',
    `point_transaction_id` BIGINT         NULL COMMENT 'FK to point_transactions once credited',
    `created_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_paypal_user` (`user_id`),
    KEY `idx_paypal_order` (`paypal_order_id`),
    KEY `idx_paypal_sub` (`paypal_subscription_id`),
    KEY `idx_paypal_status` (`status`),
    CONSTRAINT `fk_paypal_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_paypal_package` FOREIGN KEY (`package_id`) REFERENCES `point_packages` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='PayPal payment records for point purchases';

-- ============================================================
-- paypal_subscriptions: active subscription tracking
-- ============================================================
CREATE TABLE IF NOT EXISTS `paypal_subscriptions` (
    `id`                  BIGINT          NOT NULL AUTO_INCREMENT,
    `user_id`             INT             NOT NULL,
    `package_id`          INT             NOT NULL,
    `paypal_subscription_id` VARCHAR(100) NOT NULL,
    `status`              VARCHAR(30)     NOT NULL DEFAULT 'active' COMMENT 'active|suspended|cancelled|expired',
    `next_billing_date`   DATE            NULL,
    `points_per_cycle`    BIGINT          NOT NULL,
    `price_per_cycle_cad` DECIMAL(10,2)   NOT NULL,
    `started_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `cancelled_at`        TIMESTAMP       NULL,
    `updated_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_paypal_sub_id` (`paypal_subscription_id`),
    KEY `idx_sub_user` (`user_id`),
    KEY `idx_sub_status` (`status`),
    CONSTRAINT `fk_sub_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_sub_package` FOREIGN KEY (`package_id`) REFERENCES `point_packages` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Active and historical PayPal subscription tracking';

-- ============================================================
-- crypto_transactions: future crypto payment records
-- ============================================================
CREATE TABLE IF NOT EXISTS `crypto_transactions` (
    `id`                  BIGINT          NOT NULL AUTO_INCREMENT,
    `user_id`             INT             NOT NULL,
    `coin`                VARCHAR(20)     NOT NULL COMMENT 'BTC, ETH, STEEM, etc.',
    `wallet_address`      VARCHAR(200)    NOT NULL COMMENT 'Receiving wallet address',
    `tx_hash`             VARCHAR(200)    NULL COMMENT 'Blockchain transaction hash',
    `amount_coin`         DECIMAL(20,8)   NOT NULL COMMENT 'Amount in coin units',
    `amount_cad`          DECIMAL(10,2)   NOT NULL COMMENT 'Equivalent in CAD at time of transaction',
    `points_credited`     BIGINT          NOT NULL DEFAULT 0,
    `confirmations`       INT             NOT NULL DEFAULT 0,
    `required_confirmations` INT          NOT NULL DEFAULT 3,
    `status`              VARCHAR(30)     NOT NULL DEFAULT 'pending' COMMENT 'pending|confirming|completed|failed|expired',
    `point_transaction_id` BIGINT         NULL,
    `expires_at`          TIMESTAMP       NULL COMMENT 'Address expiry for unconfirmed transactions',
    `created_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_crypto_user` (`user_id`),
    KEY `idx_crypto_tx_hash` (`tx_hash`),
    KEY `idx_crypto_status` (`status`),
    CONSTRAINT `fk_crypto_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Cryptocurrency payment records (future phase)';

-- ============================================================
-- service_payments: point payments between members for services
-- ============================================================
CREATE TABLE IF NOT EXISTS `service_payments` (
    `id`                  BIGINT          NOT NULL AUTO_INCREMENT,
    `payer_user_id`       INT             NOT NULL,
    `payee_user_id`       INT             NOT NULL,
    `points`              BIGINT          NOT NULL COMMENT 'Points transferred',
    `service_description` VARCHAR(500)    NOT NULL,
    `reference_type`      VARCHAR(50)     NULL COMMENT 'todo|workshop|custom',
    `reference_id`        INT             NULL,
    `status`              VARCHAR(30)     NOT NULL DEFAULT 'completed',
    `payer_tx_id`         BIGINT          NULL COMMENT 'FK to point_transactions (debit)',
    `payee_tx_id`         BIGINT          NULL COMMENT 'FK to point_transactions (credit)',
    `created_at`          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_sp_payer` (`payer_user_id`),
    KEY `idx_sp_payee` (`payee_user_id`),
    CONSTRAINT `fk_sp_payer` FOREIGN KEY (`payer_user_id`) REFERENCES `users` (`id`),
    CONSTRAINT `fk_sp_payee` FOREIGN KEY (`payee_user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Point transfers between members for service payments';

-- ============================================================
-- site_currency_preference: per-site display currency setting
-- ============================================================
CREATE TABLE IF NOT EXISTS `site_currency_preference` (
    `id`              INT             NOT NULL AUTO_INCREMENT,
    `site_id`         INT             NOT NULL,
    `currency_code`   CHAR(3)         NOT NULL DEFAULT 'CAD',
    `updated_at`      TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_site_currency` (`site_id`),
    CONSTRAINT `fk_scp_site` FOREIGN KEY (`site_id`) REFERENCES `sites` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_scp_currency` FOREIGN KEY (`currency_code`) REFERENCES `currency_rates` (`currency_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Display currency preference per site';
