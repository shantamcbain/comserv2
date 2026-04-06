-- Membership System Schema
-- Tables for the membership, payment, and internal currency system.
-- Run against the `ency` MySQL database:
--   mysql -h HOST -u USER -pPASS ency < sql/membership_schema.sql
--
-- NOTE: Run membership_seed_data.sql after this to populate default plans.

SET FOREIGN_KEY_CHECKS = 0;

-- ============================================================
-- membership_plans
-- Defines available tiers per site. Each site has its own set of plans.
-- site_id NULL = global default (available to all sites).
-- ============================================================
CREATE TABLE IF NOT EXISTS membership_plans (
    id                  INT AUTO_INCREMENT PRIMARY KEY,
    site_id             INT,
    name                VARCHAR(255) NOT NULL,
    slug                VARCHAR(100) NOT NULL,
    description         TEXT,
    price_monthly       DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    price_annual        DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    price_currency      VARCHAR(10)   NOT NULL DEFAULT 'USD',
    ai_models_allowed   TEXT          COMMENT 'JSON array of Ollama model names allowed on this plan',
    ai_requests_per_day INT           NOT NULL DEFAULT 0,
    has_email           TINYINT(1)    NOT NULL DEFAULT 0,
    email_addresses     INT           NOT NULL DEFAULT 0 COMMENT 'Number of @sitename email addresses',
    has_hosting         TINYINT(1)    NOT NULL DEFAULT 0,
    hosting_tier        VARCHAR(50)   COMMENT 'starter, business, pro, or enterprise',
    has_subdomain       TINYINT(1)    NOT NULL DEFAULT 0,
    has_custom_domain   TINYINT(1)    NOT NULL DEFAULT 0,
    has_beekeeping      TINYINT(1)    NOT NULL DEFAULT 0,
    has_planning        TINYINT(1)    NOT NULL DEFAULT 0,
    has_currency        TINYINT(1)    NOT NULL DEFAULT 0 COMMENT 'Access to the internal coin/currency system',
    currency_bonus      DECIMAL(10,2) NOT NULL DEFAULT 0.00 COMMENT 'Coins awarded on signup/renewal',
    max_services        INT           NOT NULL DEFAULT 1,
    sort_order          INT           NOT NULL DEFAULT 0,
    is_active           TINYINT(1)    NOT NULL DEFAULT 1,
    is_featured         TINYINT(1)    NOT NULL DEFAULT 0,
    created_at          TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_site_slug (site_id, slug),
    FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- membership_plan_pricing
-- Geographic (PPP) pricing overrides per plan.
-- region_code = ISO 3166-1 alpha-2 country code, or 'DEFAULT' for fallback.
-- ============================================================
CREATE TABLE IF NOT EXISTS membership_plan_pricing (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    plan_id       INT           NOT NULL,
    region_code   VARCHAR(10)   NOT NULL COMMENT 'ISO 3166-1 alpha-2 country code or DEFAULT',
    price_monthly DECIMAL(10,2) NOT NULL,
    price_annual  DECIMAL(10,2) NOT NULL,
    currency      VARCHAR(10)   NOT NULL DEFAULT 'USD',
    created_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_plan_region (plan_id, region_code),
    FOREIGN KEY (plan_id) REFERENCES membership_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- plan_benefits
-- Specific, quantified benefits attached to a membership plan.
-- Allows per-module discounts, quotas, and feature flags.
-- ============================================================
CREATE TABLE IF NOT EXISTS plan_benefits (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    plan_id       INT           NOT NULL COMMENT 'FK to membership_plans — plan is site-scoped',
    module        VARCHAR(100)  NOT NULL COMMENT 'workshop, beekeeping, planning, ai, hosting, email, currency, domain',
    benefit_key   VARCHAR(100)  NOT NULL COMMENT 'discount_pct, discount_flat, access, requests_per_day, ...',
    benefit_type  ENUM('access','discount_pct','discount_flat','quota','feature_flag') NOT NULL DEFAULT 'access',
    benefit_value VARCHAR(500)  NOT NULL DEFAULT '0' COMMENT 'Numeric, "1"/"0" for booleans, or JSON for complex config',
    description   VARCHAR(500)  COMMENT 'Human-readable label for plan comparison pages',
    is_active     TINYINT(1)    NOT NULL DEFAULT 1,
    created_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_plan_module_key (plan_id, module, benefit_key),
    FOREIGN KEY (plan_id) REFERENCES membership_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- membership_promo_codes
-- Promotional discount codes applicable to membership subscriptions.
-- ============================================================
CREATE TABLE IF NOT EXISTS membership_promo_codes (
    id                INT AUTO_INCREMENT PRIMARY KEY,
    code              VARCHAR(50)   NOT NULL,
    description       VARCHAR(255),
    discount_type     ENUM('months_free','percent_off','fixed_amount') NOT NULL DEFAULT 'months_free',
    discount_value    DECIMAL(10,2) NOT NULL COMMENT 'Months free, percent (0-100), or fixed currency amount',
    site_id           INT           COMMENT 'NULL = valid on any site',
    plan_id           INT           COMMENT 'NULL = valid on any plan',
    max_uses          INT           COMMENT 'NULL = unlimited uses',
    uses_count        INT           NOT NULL DEFAULT 0,
    max_uses_per_user INT           NOT NULL DEFAULT 1,
    valid_from        TIMESTAMP     NULL,
    valid_until       TIMESTAMP     NULL,
    is_active         TINYINT(1)    NOT NULL DEFAULT 1,
    created_by        INT,
    created_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_code (code),
    FOREIGN KEY (site_id)     REFERENCES sites(id),
    FOREIGN KEY (plan_id)     REFERENCES membership_plans(id),
    FOREIGN KEY (created_by)  REFERENCES users(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- user_memberships
-- Active subscription records linking users to membership plans.
-- ============================================================
CREATE TABLE IF NOT EXISTS user_memberships (
    id                      INT AUTO_INCREMENT PRIMARY KEY,
    user_id                 INT           NOT NULL,
    plan_id                 INT           NOT NULL,
    site_id                 INT           NOT NULL,
    billing_cycle           ENUM('monthly','annual','one_time','free') NOT NULL DEFAULT 'monthly',
    status                  ENUM('active','grace','suspended','cancelled','expired') NOT NULL DEFAULT 'active',
    payment_provider        ENUM('paypal','patreon','internal','crypto','manual','free') NOT NULL,
    payment_reference       VARCHAR(255)  COMMENT 'External subscription or patron ID',
    price_paid              DECIMAL(10,2),
    currency_paid           VARCHAR(10),
    region_code             VARCHAR(10)   COMMENT 'Geographic region used for pricing at subscription time',
    started_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at              TIMESTAMP     NULL,
    grace_ends_at           TIMESTAMP     NULL COMMENT 'Access allowed until this time even after expiry',
    cancelled_at            TIMESTAMP     NULL,
    cancellation_reason     TEXT,
    notes                   TEXT,
    autopay_enabled         TINYINT(1)    NOT NULL DEFAULT 0,
    autopay_method          ENUM('coins','paypal'),
    autopay_topup_coins     INT           NOT NULL DEFAULT 0 COMMENT 'Fixed coin top-up amount (0 = exact renewal cost)',
    renewal_warning_sent_at TIMESTAMP     NULL,
    created_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id)  REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (plan_id)  REFERENCES membership_plans(id),
    FOREIGN KEY (site_id)  REFERENCES sites(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- payment_transactions
-- Unified payment ledger for the entire application.
-- Covers memberships, domains, workshops, hosting, services,
-- and internal currency purchases via payable_type + payable_id.
-- ============================================================
CREATE TABLE IF NOT EXISTS payment_transactions (
    id                      INT AUTO_INCREMENT PRIMARY KEY,
    user_id                 INT           NOT NULL,
    payable_type            VARCHAR(100)  NOT NULL COMMENT 'membership, domain, workshop, hosting, service, currency_purchase',
    payable_id              INT           COMMENT 'FK into referenced table (no DB-level constraint due to polymorphism)',
    amount                  DECIMAL(10,2) NOT NULL,
    currency                VARCHAR(10)   NOT NULL DEFAULT 'USD',
    provider                ENUM('paypal','patreon','internal','crypto','manual') NOT NULL,
    provider_transaction_id VARCHAR(255)  COMMENT 'Provider transaction/IPN reference — unique per provider',
    status                  ENUM('pending','completed','failed','refunded','disputed') NOT NULL DEFAULT 'pending',
    description             VARCHAR(500),
    metadata                TEXT          COMMENT 'JSON blob for provider-specific data',
    ip_address              VARCHAR(45),
    created_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_provider_txn (provider, provider_transaction_id),
    FOREIGN KEY (user_id) REFERENCES users(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- internal_currency_accounts
-- One row per user. Tracks the user's internal coin/credit balance.
-- All balance mutations must use SELECT ... FOR UPDATE to prevent double-spend.
-- ============================================================
CREATE TABLE IF NOT EXISTS internal_currency_accounts (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    user_id         INT            NOT NULL UNIQUE,
    balance         DECIMAL(14,4)  NOT NULL DEFAULT 0.0000,
    lifetime_earned DECIMAL(14,4)  NOT NULL DEFAULT 0.0000 COMMENT 'Total coins ever credited (stats/anti-fraud)',
    lifetime_spent  DECIMAL(14,4)  NOT NULL DEFAULT 0.0000,
    created_at      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- internal_currency_transactions
-- Immutable ledger of every coin movement. Append-only — never update/delete.
-- from_user_id NULL = system credit. to_user_id NULL = system debit.
-- ============================================================
CREATE TABLE IF NOT EXISTS internal_currency_transactions (
    id               INT AUTO_INCREMENT PRIMARY KEY,
    from_user_id     INT           COMMENT 'NULL = system/external credit source',
    to_user_id       INT           COMMENT 'NULL = system/service debit destination',
    amount           DECIMAL(14,4) NOT NULL,
    transaction_type ENUM('purchase','earn','spend','transfer','bonus','refund','adjustment') NOT NULL,
    description      VARCHAR(500),
    reference_type   VARCHAR(100)  COMMENT 'membership, payment_transaction, workshop, service, etc.',
    reference_id     INT,
    balance_after    DECIMAL(14,4) NOT NULL COMMENT 'Snapshot of to_user balance after this transaction for audit',
    created_at       TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (from_user_id) REFERENCES users(id),
    FOREIGN KEY (to_user_id)   REFERENCES users(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- system_cost_tracking
-- Operational expenses so admins can verify pricing covers infrastructure costs.
-- site_id NULL = global/shared infrastructure cost.
-- ============================================================
CREATE TABLE IF NOT EXISTS system_cost_tracking (
    id                INT AUTO_INCREMENT PRIMARY KEY,
    cost_category     VARCHAR(100)  NOT NULL COMMENT 'power_electricity, cooling_hvac, hardware_servers, ai_ollama_gpu, email_service, programming_labor, ...',
    description       VARCHAR(500),
    amount            DECIMAL(10,2) NOT NULL,
    currency          VARCHAR(10)   NOT NULL DEFAULT 'USD',
    site_id           INT           COMMENT 'NULL = global/shared infrastructure cost',
    period_start      DATE          NOT NULL,
    period_end        DATE          NOT NULL,
    is_recurring      TINYINT(1)    NOT NULL DEFAULT 0 COMMENT 'Monthly recurring vs one-time expense',
    vendor            VARCHAR(255),
    invoice_reference VARCHAR(255),
    created_by        INT,
    created_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (site_id)    REFERENCES sites(id),
    FOREIGN KEY (created_by) REFERENCES users(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- membership_service_access
-- Explicit service grants derived from membership or manually overridden.
-- UNIQUE on (user_id, site_id, service_name) — upserted on membership change.
-- ============================================================
CREATE TABLE IF NOT EXISTS membership_service_access (
    id            INT AUTO_INCREMENT PRIMARY KEY,
    user_id       INT          NOT NULL,
    site_id       INT          NOT NULL,
    service_name  VARCHAR(100) NOT NULL COMMENT 'beekeeping, planning, ai_models, email, hosting, currency, subdomain, custom_domain',
    granted_by    ENUM('membership','manual','admin') NOT NULL DEFAULT 'membership',
    membership_id INT          COMMENT 'FK to user_memberships (NULL for manual/admin grants)',
    is_active     TINYINT(1)   NOT NULL DEFAULT 1,
    granted_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at    TIMESTAMP    NULL,
    UNIQUE KEY uq_user_site_service (user_id, site_id, service_name),
    FOREIGN KEY (user_id)       REFERENCES users(id) ON DELETE CASCADE,
    FOREIGN KEY (site_id)       REFERENCES sites(id),
    FOREIGN KEY (membership_id) REFERENCES user_memberships(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================
-- plan_audit
-- Audit trail for changes to membership plans and memberships.
-- ============================================================
CREATE TABLE IF NOT EXISTS plan_audit (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    entity_type    VARCHAR(50)  NOT NULL COMMENT 'membership_plan, user_membership, plan_benefit, ...',
    entity_id      INT          NOT NULL,
    action         VARCHAR(50)  NOT NULL COMMENT 'create, update, delete, activate, deactivate, ...',
    user_id        INT,
    username       VARCHAR(255),
    changed_fields JSON,
    ip_address     VARCHAR(45),
    created_at     TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

SET FOREIGN_KEY_CHECKS = 1;
