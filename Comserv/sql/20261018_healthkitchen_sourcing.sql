-- HealthKitchen: production/sourcing attributes, reference factors, user preferences.
-- NOT APPLIED. Apply via Admin > Schema Compare (columns + table) and then run the
-- seed INSERTs below, or run this whole file manually after approval.
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

-- 4) Seed (20 rows). Adjustments are deliberately conservative approximations.
INSERT IGNORE INTO hk_sourcing_factor
 (food_category, attribute, attr_value, nutrient_adj_json, pesticide_risk, antibiotic_risk, hormone_risk, heavy_metal_risk, ethics_score, notes, citation, created_at, updated_at) VALUES
('beef','animal_raising','grass_fed','{"fat_g":-15,"calories":-8}',NULL,'low','low',NULL,4,'Leaner; higher omega-3, CLA and vitamin E precursors; better n-6:n-3 ratio.','Daley CA, Abbott A, Doyle PS, Nader GA, Larson S. A review of fatty acid profiles and antioxidant content in grass-fed and grain-fed beef. Nutr J. 2010;9:10.',NOW(),NOW()),
('beef','animal_raising','feedlot','{"fat_g":10,"calories":5}',NULL,'med','high',NULL,1,'Grain finishing raises marbling; growth-promoting hormone implants are permitted in US/Canada conventional beef.','US FDA. Steroid Hormone Implants Used for Growth in Food-Producing Animals (2022); US FDA 2022 Summary Report on Antimicrobials Sold or Distributed for Use in Food-Producing Animals.',NOW(),NOW()),
('beef','production','organic_certified',NULL,'low','low','low',NULL,3,'Organic standards prohibit routine antibiotics and growth hormones; require pasture access.','USDA National Organic Program, 7 CFR 205.237-205.239 (livestock feed, health care and living conditions); Canada Organic Regime CAN/CGSB-32.310.',NOW(),NOW()),
('dairy','production','organic_certified',NULL,'low','low','low',NULL,3,'Organic milk ~60% more omega-3 (ALA) than conventional.','Benbrook CM, Butler G, Latif MA, Leifert C, Davis DR. Organic production enhances milk nutritional quality by shifting fatty acid composition. PLoS ONE. 2013;8(12):e82429.',NOW(),NOW()),
('dairy','animal_raising','grass_fed',NULL,NULL,'low',NULL,NULL,4,'Grass-fed milk has the best n-6:n-3 ratio (~1:1) and higher CLA.','Benbrook CM, Davis DR, Heins BJ, et al. Enhancing the fatty acid profile of milk through forage-based rations. Food Sci Nutr. 2018;6(3):681-700.',NOW(),NOW()),
('eggs','animal_raising','pasture',NULL,NULL,'low',NULL,NULL,4,'Pastured hens: ~2x vitamin E and higher omega-3 in yolks.','Karsten HD, Patterson PH, Stout R, Crews G. Vitamins A, E and fatty acid composition of the eggs of caged hens and pastured hens. Renew Agric Food Syst. 2010;25(1):45-54.',NOW(),NOW()),
('eggs','animal_raising','caged',NULL,NULL,'med',NULL,NULL,1,'Conventional cages severely restrict behaviour; welfare risk ranked highest.','EFSA AHAW Panel. Welfare of laying hens on farm. EFSA Journal. 2023;21(2):7789.',NOW(),NOW()),
('eggs','animal_raising','free_range',NULL,NULL,'low',NULL,NULL,3,'Outdoor access; welfare better than caged/barn systems.','EFSA AHAW Panel. Welfare of laying hens on farm. EFSA Journal. 2023;21(2):7789.',NOW(),NOW()),
('chicken','production','organic_certified',NULL,'low','low',NULL,NULL,3,'Organic meat ~50% more omega-3; no routine antibiotics.','Srednicka-Tober D, Baranski M, Seal C, et al. Composition differences between organic and conventional meat: a systematic literature review and meta-analysis. Br J Nutr. 2016;115(6):994-1011.',NOW(),NOW()),
('chicken','production','conventional',NULL,NULL,'med',NULL,NULL,2,'Medically important antimicrobials still sold for poultry use; hormones are NOT permitted in poultry (US/Canada).','US FDA 2022 Summary Report on Antimicrobials Sold or Distributed for Use in Food-Producing Animals; 21 CFR 556 (no hormones approved for poultry).',NOW(),NOW()),
('salmon','catch_method','farmed','{"fat_g":30,"calories":15}',NULL,'med',NULL,'med',2,'Farmed Atlantic ~13 g fat/100 g vs ~6 g wild; higher PCB/dioxin levels reported.','Hites RA, Foran JA, Carpenter DO, et al. Global assessment of organic contaminants in farmed salmon. Science. 2004;303(5655):226-229; USDA FoodData Central #175168 (farmed) vs #173686 (wild).',NOW(),NOW()),
('salmon','catch_method','wild','{"fat_g":-30,"calories":-15}',NULL,'low',NULL,'low',4,'Leaner; lower persistent organic contaminants. Prefer MSC-certified stocks.','USDA FoodData Central #173686 (Atlantic salmon, wild, raw); Hites RA et al. Science. 2004;303:226-229.',NOW(),NOW()),
('fish_other','catch_method','wild',NULL,NULL,'low',NULL,'med',3,'Large predatory wild fish (tuna, swordfish) accumulate mercury; choose smaller species.','US FDA/EPA. Advice about Eating Fish (2021 update), mercury levels in commercial fish.',NOW(),NOW()),
('leafy_greens','production','organic_certified',NULL,'low',NULL,NULL,'low',3,'Pesticide residues ~4x less frequent in organic crops; lower cadmium.','Baranski M, Srednicka-Tober D, Volakakis N, et al. Higher antioxidant and lower cadmium concentrations and lower incidence of pesticide residues in organically grown crops. Br J Nutr. 2014;112(5):794-811.',NOW(),NOW()),
('leafy_greens','production','conventional',NULL,'high',NULL,NULL,NULL,2,'Spinach/kale/collards rank among highest multi-residue produce.','Environmental Working Group. 2024 Shopper''s Guide to Pesticides in Produce (analysis of USDA Pesticide Data Program results).',NOW(),NOW()),
('berries','production','conventional',NULL,'high',NULL,NULL,NULL,2,'Strawberries/blueberries frequently carry multiple residues.','USDA Agricultural Marketing Service. Pesticide Data Program Annual Summary, Calendar Year 2022; EWG 2024 Shopper''s Guide.',NOW(),NOW()),
('berries','production','organic_certified',NULL,'low',NULL,NULL,NULL,3,'Organic berries markedly fewer residues; higher polyphenols reported.','Baranski M et al. Br J Nutr. 2014;112(5):794-811.',NOW(),NOW()),
('apples','production','conventional',NULL,'high',NULL,NULL,NULL,2,'Apples consistently show multiple residues (e.g., diphenylamine post-harvest).','USDA Agricultural Marketing Service. Pesticide Data Program Annual Summary, Calendar Year 2022.',NOW(),NOW()),
('corn','gmo','gmo',NULL,'med',NULL,NULL,NULL,2,'No substantiated nutrition or safety difference; herbicide-tolerant traits linked to higher glyphosate use.','National Academies of Sciences, Engineering, and Medicine. Genetically Engineered Crops: Experiences and Prospects. Washington DC: The National Academies Press; 2016.',NOW(),NOW()),
('soy','gmo','gmo',NULL,'med',NULL,NULL,NULL,2,'No substantiated nutrition or safety difference; herbicide-tolerant traits linked to higher glyphosate use.','National Academies of Sciences, Engineering, and Medicine. Genetically Engineered Crops: Experiences and Prospects. 2016.',NOW(),NOW()),
('any','local','local',NULL,NULL,NULL,NULL,NULL,4,'Within 160 km. Shorter supply chains; environmental benefit depends on production method more than distance.','Edwards-Jones G. Does eating local food reduce the environmental impact of food production and enhance consumer health? Proc Nutr Soc. 2010;69(4):582-591.',NOW(),NOW());
