-- HealthKitchen: production/sourcing attributes, reference factors, user preferences.
-- NOT APPLIED. Apply via Admin > Schema Compare (columns + table). No manual seeding:
-- the 21 reference rows live in lib/Comserv/Util/HealthKitchen/SourcingSeed.pm and are
-- inserted automatically (insert-if-missing) on the first HealthKitchen request after the
-- table exists. This file is kept as a reference for a manual DDL apply only.
-- All new columns are nullable; the app checks for them and shows
-- "create columns first" until they exist.

-- 1) Sourcing attributes on product details
ALTER TABLE hk_item_product
  ADD COLUMN food_category  VARCHAR(30)  NULL AFTER size_unit,
  ADD COLUMN production     VARCHAR(30)  NULL AFTER food_category,   -- organic_certified|conventional|transitional|unknown
  ADD COLUMN animal_raising VARCHAR(30)  NULL AFTER production,      -- grass_fed|pasture|feedlot|free_range|caged|na
  ADD COLUMN catch_method   VARCHAR(20)  NULL AFTER animal_raising,  -- wild|farmed|na
  ADD COLUMN gmo            VARCHAR(30)  NULL AFTER catch_method,    -- non_gmo_verified|gmo|unknown
  ADD COLUMN local_km       INT          NULL AFTER gmo,             -- distance from producer; <=160 counts as local
  ADD COLUMN certifier      VARCHAR(100) NULL AFTER local_km,
  ADD COLUMN cert_verified  TINYINT      NULL AFTER certifier;       -- user-entered, not independently verified

-- 2) User preferences on health profile
ALTER TABLE hk_user_health_profile
  ADD COLUMN prefer_organic TINYINT NULL,
  ADD COLUMN avoid_feedlot  TINYINT NULL,
  ADD COLUMN ethics_weight  TINYINT NULL;   -- 0-5; NULL treated as 0 (off)

-- 3) Reference factors
CREATE TABLE IF NOT EXISTS hk_sourcing_factor (
  id                INT NOT NULL AUTO_INCREMENT,
  food_category     VARCHAR(30) NOT NULL,   -- 'any' matches every category
  attribute         VARCHAR(30) NOT NULL,   -- production|animal_raising|catch_method|gmo|local
  attr_value        VARCHAR(30) NOT NULL,
  nutrient_adj_json TEXT NULL,              -- percent change vs unspecified-source base values
  pesticide_risk    VARCHAR(4) NULL,        -- low|med|high
  antibiotic_risk   VARCHAR(4) NULL,
  hormone_risk      VARCHAR(4) NULL,
  heavy_metal_risk  VARCHAR(4) NULL,        -- heavy metals / persistent contaminants (PCBs, mercury)
  ethics_score      TINYINT NULL,           -- 0 (worst) .. 5 (best)
  notes             TEXT NULL,
  citation          TEXT NOT NULL,
  created_at        DATETIME NULL,
  updated_at        DATETIME NULL,
  PRIMARY KEY (id),
  UNIQUE KEY hk_factor_key (food_category, attribute, attr_value)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 4) Seed rows: see lib/Comserv/Util/HealthKitchen/SourcingSeed.pm (auto-seeded).
