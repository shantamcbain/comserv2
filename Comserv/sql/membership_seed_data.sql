-- Membership System Seed Data
-- Default membership plans for core sites
-- Run: mysql -h HOST -u USER -pPASS ency < sql/membership_seed_data.sql

-- ============================================================
-- CSC (site_id=1) Membership Plans
-- ============================================================
INSERT INTO membership_plans
    (site_id, name, slug, description,
     price_monthly, price_annual, price_currency,
     ai_models_allowed, ai_requests_per_day,
     has_email, email_addresses,
     has_hosting, hosting_tier,
     has_subdomain, has_custom_domain,
     has_beekeeping, has_planning, has_currency, currency_bonus,
     max_services, sort_order, is_active, is_featured)
VALUES
-- Free tier
(1, 'Free', 'free',
 'Basic access to Computer System Consulting services. Browse resources, access community forums, and try entry-level AI tools.',
 0.00, 0.00, 'USD',
 '[]', 0,
 0, 0, 0, NULL, 0, 0, 0, 0, 0, 0.00,
 1, 1, 1, 0),

-- Basic tier
(1, 'Basic', 'basic',
 'For individuals who want enhanced AI assistance and access to the planning module. Includes 10 AI requests per day.',
 5.00, 50.00, 'USD',
 '["llama3.2","mistral"]', 10,
 0, 0, 0, NULL, 0, 0, 0, 1, 1, 10.00,
 2, 2, 1, 0),

-- Pro tier (featured)
(1, 'Pro', 'pro',
 'For professionals needing advanced AI models, a CSC email address, subdomain hosting, and full service access including beekeeping tools.',
 15.00, 150.00, 'USD',
 '["llama3.2","mistral","codellama","gemma2"]', 30,
 1, 1, 1, 'starter', 1, 0, 1, 1, 1, 50.00,
 5, 3, 1, 1),

-- Business tier
(1, 'Business', 'business',
 'Full access to all CSC services. Includes multiple email addresses, business hosting, custom domain, all AI models, and priority support.',
 30.00, 300.00, 'USD',
 '["llama3.2","mistral","codellama","gemma2","deepseek-r1","llava","phi3"]', 100,
 1, 3, 1, 'business', 1, 1, 1, 1, 1, 200.00,
 10, 4, 1, 0);

-- ============================================================
-- MCoop (site_id=11) Membership Plans
-- ============================================================
INSERT INTO membership_plans
    (site_id, name, slug, description,
     price_monthly, price_annual, price_currency,
     ai_models_allowed, ai_requests_per_day,
     has_email, email_addresses,
     has_hosting, hosting_tier,
     has_subdomain, has_custom_domain,
     has_beekeeping, has_planning, has_currency, currency_bonus,
     max_services, sort_order, is_active, is_featured)
VALUES
(11, 'Community', 'community',
 'Free membership for MCoop community members. Access to community forums and basic planning tools.',
 0.00, 0.00, 'USD',
 '[]', 0,
 0, 0, 0, NULL, 0, 0, 0, 1, 1, 5.00,
 2, 1, 1, 0),

(11, 'Member', 'member',
 'Full MCoop member access with AI tools, beekeeping module, and internal currency for peer-to-peer services.',
 8.00, 80.00, 'USD',
 '["llama3.2","mistral"]', 20,
 0, 0, 0, NULL, 0, 0, 1, 1, 1, 25.00,
 5, 2, 1, 1),

(11, 'Supporter', 'supporter',
 'Support MCoop with a higher tier. Includes subdomain, extended AI access, and a larger currency bonus on signup.',
 20.00, 200.00, 'USD',
 '["llama3.2","mistral","codellama","gemma2"]', 50,
 1, 1, 1, 'starter', 1, 0, 1, 1, 1, 100.00,
 8, 3, 1, 0);

-- ============================================================
-- Monashee (site_id=4) Membership Plans
-- ============================================================
INSERT INTO membership_plans
    (site_id, name, slug, description,
     price_monthly, price_annual, price_currency,
     ai_models_allowed, ai_requests_per_day,
     has_email, email_addresses,
     has_hosting, hosting_tier,
     has_subdomain, has_custom_domain,
     has_beekeeping, has_planning, has_currency, currency_bonus,
     max_services, sort_order, is_active, is_featured)
VALUES
(4, 'Basic', 'basic',
 'Free access to Monashee community resources and planning tools.',
 0.00, 0.00, 'USD',
 '[]', 0,
 0, 0, 0, NULL, 0, 0, 0, 1, 0, 0.00,
 1, 1, 1, 0),

(4, 'Member', 'member',
 'Full Monashee member with AI tools, beekeeping module, and community currency.',
 10.00, 100.00, 'USD',
 '["llama3.2","mistral"]', 15,
 0, 0, 0, NULL, 0, 0, 1, 1, 1, 30.00,
 4, 2, 1, 1);

-- ============================================================
-- Shanta (site_id=8) Membership Plans (developer/admin site)
-- ============================================================
INSERT INTO membership_plans
    (site_id, name, slug, description,
     price_monthly, price_annual, price_currency,
     ai_models_allowed, ai_requests_per_day,
     has_email, email_addresses,
     has_hosting, hosting_tier,
     has_subdomain, has_custom_domain,
     has_beekeeping, has_planning, has_currency, currency_bonus,
     max_services, sort_order, is_active, is_featured)
VALUES
(8, 'Developer', 'developer',
 'Full developer access — all AI models, all services, unlimited requests. Admin use only.',
 0.00, 0.00, 'USD',
 '["llama3.2","mistral","codellama","gemma2","deepseek-r1","llava","phi3","qwen2.5","solar"]', 9999,
 1, 5, 1, 'enterprise', 1, 1, 1, 1, 1, 1000.00,
 99, 1, 1, 0);

-- ============================================================
-- CSC Hosting Plans (site_id=1)
-- Available to members of any SiteName whose site is
-- registered with CSC.  These plans appear in the membership
-- index of every SiteName, with a CTA to register with CSC.
-- ============================================================
INSERT INTO membership_plans
    (site_id, name, slug, description,
     price_monthly, price_annual, price_currency,
     ai_models_allowed, ai_requests_per_day,
     has_email, email_addresses,
     has_hosting, hosting_tier,
     has_subdomain, has_custom_domain,
     has_beekeeping, has_planning, has_currency, currency_bonus,
     max_services, sort_order, is_active, is_featured)
VALUES
-- Subdomain Hosting: app served under a SiteName parent domain
(1, 'Subdomain Hosting', 'hosting-subdomain',
 'Get your own subdomain on any registered SiteName domain (e.g. you.forager.com). '
 'Your site runs as an app on the CSC platform — no cPanel required. '
 'Includes full access to ENCY, AI tools, and planning modules.',
 10.00, 100.00, 'CAD',
 '["llama3.2","mistral"]', 20,
 0, 0, 1, 'app-subdomain', 1, 0, 0, 1, 1, 25.00,
 3, 10, 1, 0),

-- App-Only Hosting: standalone app site, no cPanel, no subdomain on partner domain
(1, 'App-Only Hosting', 'hosting-app',
 'Host your own standalone application on the CSC platform. '
 'Bring your own domain or use a CSC sub-path. '
 'Ideal for co-ops, clubs, or small businesses that need a managed web presence '
 'without the overhead of a cPanel account.',
 15.00, 150.00, 'CAD',
 '["llama3.2","mistral","codellama"]', 30,
 0, 0, 1, 'app-only', 0, 1, 0, 1, 1, 50.00,
 5, 11, 1, 1)
ON DUPLICATE KEY UPDATE
    description    = VALUES(description),
    price_monthly  = VALUES(price_monthly),
    price_annual   = VALUES(price_annual),
    hosting_tier   = VALUES(hosting_tier),
    has_subdomain  = VALUES(has_subdomain),
    has_custom_domain = VALUES(has_custom_domain),
    is_active      = VALUES(is_active),
    is_featured    = VALUES(is_featured);
