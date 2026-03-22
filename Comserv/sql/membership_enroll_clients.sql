-- Enroll all site clients as Basic members, paying by internal currency
-- Run: mysql -h HOST -u USER -pPASS ency < sql/membership_enroll_clients.sql

-- ============================================================
-- Step 1: Create Basic plans for sites that don't have one
-- (CSC=1 and Monashee=4 already have Basic plans)
-- ============================================================
INSERT IGNORE INTO membership_plans
    (site_id, name, slug, description,
     price_monthly, price_annual, price_currency,
     ai_models_allowed, ai_requests_per_day,
     has_email, email_addresses,
     has_hosting, hosting_tier,
     has_subdomain, has_custom_domain,
     has_beekeeping, has_planning, has_currency, currency_bonus,
     max_services, sort_order, is_active, is_featured)
VALUES
(2,  'Basic', 'basic', 'Basic BMaster membership. AI planning tools and internal currency.',        5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(3,  'Basic', 'basic', 'Basic Forager membership. AI planning tools and internal currency.',        5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(5,  'Basic', 'basic', 'Basic Ve7tit membership. AI planning tools and internal currency.',         5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(6,  'Basic', 'basic', 'Basic Sunfire membership. AI planning tools and internal currency.',        5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(8,  'Basic', 'basic', 'Basic Shanta membership. AI planning tools and internal currency.',         5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(9,  'Basic', 'basic', 'Basic ENCY membership. AI planning tools and internal currency.',           5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(10, 'Basic', 'basic', 'Basic USBM membership. AI planning tools and internal currency.',           5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(11, 'Basic', 'basic', 'Basic MCoop membership. AI planning tools, beekeeping, and currency.',      5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,1,1,1,10.00, 2,2,1,0),
(12, 'Basic', 'basic', 'Basic CountryStores membership. AI planning tools and internal currency.',  5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(13, 'Basic', 'basic', 'Basic 3d membership. AI planning tools and internal currency.',             5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(25, 'Basic', 'basic', 'Basic WeaverBeck membership. AI planning tools and internal currency.',     5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(26, 'Basic', 'basic', 'Basic SB membership. AI planning tools and internal currency.',             5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0),
(27, 'Basic', 'basic', 'Basic AltPower membership. AI planning tools and internal currency.',       5.00, 50.00, 'USD', '["llama3.2","mistral"]', 10, 0,0,0,NULL,0,0,0,1,1,10.00, 2,2,1,0);

-- ============================================================
-- Step 2: Internal currency accounts for real users
-- Shanta=178, mnickers=227
-- Give 100 coins each to start
-- ============================================================
INSERT IGNORE INTO internal_currency_accounts
    (user_id, balance, lifetime_earned, lifetime_spent)
VALUES
(178, 100.0000, 100.0000, 0.0000),
(227, 100.0000, 100.0000, 0.0000);

-- Seed transaction records for the initial coin grant
INSERT INTO internal_currency_transactions
    (from_user_id, to_user_id, amount, transaction_type, balance_after, description, reference_type)
SELECT NULL, 178, 100.0000, 'bonus', 100.0000, 'Initial coin grant — client setup', 'admin_grant'
WHERE NOT EXISTS (
    SELECT 1 FROM internal_currency_transactions WHERE to_user_id = 178 AND reference_type = 'admin_grant' LIMIT 1
);
INSERT INTO internal_currency_transactions
    (from_user_id, to_user_id, amount, transaction_type, balance_after, description, reference_type)
SELECT NULL, 227, 100.0000, 'bonus', 100.0000, 'Initial coin grant — client setup', 'admin_grant'
WHERE NOT EXISTS (
    SELECT 1 FROM internal_currency_transactions WHERE to_user_id = 227 AND reference_type = 'admin_grant' LIMIT 1
);

-- ============================================================
-- Step 3: Enroll Shanta (user_id=178) as Basic member of every site
-- ============================================================
INSERT IGNORE INTO user_memberships
    (user_id, plan_id, site_id, billing_cycle, status, payment_provider,
     payment_reference, price_paid, currency_paid, region_code)
SELECT
    178,
    mp.id,
    mp.site_id,
    'monthly',
    'active',
    'internal',
    CONCAT('internal-shanta-', mp.site_id),
    5.00,
    'USD',
    'CA'
FROM membership_plans mp
WHERE mp.slug = 'basic'
  AND mp.is_active = 1
  AND mp.site_id IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM user_memberships um
      WHERE um.user_id = 178 AND um.site_id = mp.site_id AND um.status IN ('active','grace')
  );

-- ============================================================
-- Step 4: Enroll mnickers (user_id=227) as Basic member of
--         CSC(1), BMaster(2), Shanta(8)
-- ============================================================
INSERT IGNORE INTO user_memberships
    (user_id, plan_id, site_id, billing_cycle, status, payment_provider,
     payment_reference, price_paid, currency_paid, region_code)
SELECT
    227,
    mp.id,
    mp.site_id,
    'monthly',
    'active',
    'internal',
    CONCAT('internal-mnickers-', mp.site_id),
    5.00,
    'USD',
    'CA'
FROM membership_plans mp
WHERE mp.slug = 'basic'
  AND mp.is_active = 1
  AND mp.site_id IN (1, 2, 8)
  AND NOT EXISTS (
      SELECT 1 FROM user_memberships um
      WHERE um.user_id = 227 AND um.site_id = mp.site_id AND um.status IN ('active','grace')
  );
