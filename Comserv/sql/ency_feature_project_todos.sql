-- ============================================================
-- ENCY Encyclopedia Feature — Project & Todo Registration
-- Branch: ency-53b0
-- Date: 2026-03-30
-- Run against: ency database
-- ============================================================
-- PURPOSE: Inserts project tracking records and phase todo items
-- into the ency project/todo system. This is DATA insertion only.
-- ============================================================
-- SCHEMA PROTOCOL: New tables are defined as DBIx::Class Result
-- files under Comserv/lib/Comserv/Model/Schema/. Admin runs
-- schema compare to generate DDL and apply to database.
-- ============================================================

USE `ency`;

-- ============================================================
-- 1. PARENT PROJECT: Encyclopedia of Biological Life (ENCY)
-- ============================================================

INSERT INTO `projects`
    (`name`, `description`, `start_date`, `end_date`, `status`,
     `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
     `developer_name`, `client_name`, `sitename`, `comments`,
     `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`)
SELECT
    'Encyclopedia of Biological Life',
    'Comprehensive biological reference database. Branch: ency-53b0. PRD: .zenflow/tasks/ency-53b0/requirements.md. Covers: herbs (existing, fix/standardize), animals, insects, diseases (human/animal/plant/insect), symptoms, chemical constituents (mapped to herbs/foods/drugs), glossary of terms, cross-referencing junction tables between all entities, and AI-assisted data entry and search fallback. All new tables defined as DBIx::Class Result files in Comserv/lib/Comserv/Model/Schema/Forager/Result/. Admin runs schema compare to apply DDL.',
    '2026-03-30',
    '2027-06-30',
    'In-Process',
    0,
    'ENCY',
    50,
    420,
    'Shanta',
    'ENCY',
    'ENCY',
    'Branch: ency-53b0. 5-phase delivery. Phase1=Herb Fix, Phase2=New Entities, Phase3=Cross-Refs, Phase4=AI, Phase5=Global Search.',
    'Shanta',
    'admin',
    NOW(),
    NULL
WHERE NOT EXISTS (
    SELECT 1 FROM `projects`
    WHERE `project_code` = 'ENCY' AND `sitename` = 'ENCY'
);

-- Helper: get the ENCY project id
SET @ency_project_id = (
    SELECT `id` FROM `projects`
    WHERE `project_code` = 'ENCY' AND `sitename` = 'ENCY'
    ORDER BY `id` DESC LIMIT 1
);

-- ============================================================
-- 2. PHASE TODO ITEMS
-- ============================================================

-- ----------------------------------------------------------------
-- Phase 1 — Herb Foundation: Fix & Standardize Existing
-- ----------------------------------------------------------------
INSERT INTO `todo`
    (`sitename`, `start_date`, `due_date`, `subject`, `description`,
     `estimated_man_hours`, `project_code`, `developer`, `username_of_poster`,
     `status`, `priority`, `share`, `last_mod_by`, `last_mod_date`,
     `group_of_poster`, `project_id`, `date_time_posted`)
SELECT
    'ENCY',
    '2026-03-30',
    '2026-04-30',
    'Phase 1: Herb Foundation — Fix & Standardize',
    'Branch ency-53b0. Fix existing herb implementation and standardize to coding standards.

BUGS TO FIX:
- HerbView.tt checks mode == ''view''/''edit'' but controller stashes edit_mode => 0/1. Fix to use consistent variable.
- Missing $c->forward($c->view(''TT'')) in BotanicalNameView, BeePastureView, herb_detail actions.
- add_herb logging call missing log level argument (wrong signature).
- BotanicalNameView.tt and BeePastureView.tt use hardcoded admin group checks instead of c.session.roles.

SCHEMA FIXES (Result files only — admin runs schema compare for DDL):
Table: references (Ency schema, Comserv/lib/Comserv/Model/Schema/Ency/Result/Reference.pm)
  Existing: reference_id (PK), reference_system
  Add: title VARCHAR(500), author VARCHAR(500), publication_date DATE,
       publisher VARCHAR(255), isbn VARCHAR(30), url TEXT, notes TEXT,
       sitename VARCHAR(100), username_of_poster VARCHAR(50), date_time_posted VARCHAR(30)

Table: categories (Ency schema, Comserv/lib/Comserv/Model/Schema/Ency/Result/Category.pm)
  Existing: category_id (PK), category
  Add: description TEXT, parent_category_id INT (self-ref FK), entity_type VARCHAR(50),
       sitename VARCHAR(100)

TEMPLATE STANDARDS (all existing ENCY templates):
- Add [% META title=... description=... roles=... TemplateType=''Application'' category=''ENCY'' page_version=''0.01'' last_updated=''...'' %]
- Add [% PageVersion = ''ENCY/TemplateName.tt,v 0.01 ...'' %]
- Replace hardcoded role checks with c.session.roles
- Add flash message blocks (error_msg, success_msg) to all interactive templates
- Apply app-container / theme CSS class structure

DELIVERABLES: Working herb list, detail view, add, edit, search. All templates coding-standards compliant.',
    80,
    'ENCY',
    'Shanta',
    'Shanta',
    'Requested',
    1,
    0,
    'Shanta',
    CURDATE(),
    'admin',
    @ency_project_id,
    NOW()
WHERE NOT EXISTS (
    SELECT 1 FROM `todo`
    WHERE `subject` = 'Phase 1: Herb Foundation — Fix & Standardize'
    AND `project_id` = @ency_project_id
);

-- ----------------------------------------------------------------
-- Phase 2 — New Entity Databases
-- ----------------------------------------------------------------
INSERT INTO `todo`
    (`sitename`, `start_date`, `due_date`, `subject`, `description`,
     `estimated_man_hours`, `project_code`, `developer`, `username_of_poster`,
     `status`, `priority`, `share`, `last_mod_by`, `last_mod_date`,
     `group_of_poster`, `project_id`, `date_time_posted`)
SELECT
    'ENCY',
    '2026-05-01',
    '2026-08-31',
    'Phase 2: New Entities — Animals, Insects, Diseases, Symptoms, Constituents, Glossary',
    'Branch ency-53b0. Implement 6 new encyclopedia entity types. Each gets: DBIx::Class Result file, ENCYModel methods, ENCY controller actions (index/list/detail/add/edit/search), TT templates (PascalCase, META blocks, coding-standards compliant).

All new tables go in the shanta_forager database.
Result files go in: Comserv/lib/Comserv/Model/Schema/Forager/Result/
Admin runs schema compare to generate DDL and apply to database.

--- TABLE: ency_animal_tb ---
Result file: Comserv/lib/Comserv/Model/Schema/Forager/Result/Animal.pm
Columns:
  record_id        INT PK AUTO_INCREMENT
  common_name      VARCHAR(255) NOT NULL
  scientific_name  VARCHAR(255)
  kingdom          VARCHAR(100)   -- Animalia
  phylum           VARCHAR(100)   -- eg Chordata
  class_name       VARCHAR(100)   -- eg Mammalia
  order_name       VARCHAR(100)
  family_name      VARCHAR(100)
  genus            VARCHAR(100)
  species          VARCHAR(100)
  habitat          TEXT
  diet             TEXT
  behavior         TEXT
  ecological_role  TEXT           -- pollinator, predator, decomposer, etc.
  therapeutic_uses TEXT           -- medicinal uses of animal products
  veterinary_uses  TEXT
  distribution     TEXT
  conservation_status VARCHAR(100) -- eg Least Concern, Endangered
  image            VARCHAR(500)
  url              TEXT
  history          TEXT
  reference        TEXT
  constituents     TEXT           -- animal-derived compounds (venom, bile, etc.)
  sitename         VARCHAR(100) DEFAULT ''ENCY''
  username_of_poster VARCHAR(50)
  group_of_poster  VARCHAR(50)
  date_time_posted VARCHAR(30)
  share            INT DEFAULT 0

--- TABLE: ency_insect_tb ---
Result file: Comserv/lib/Comserv/Model/Schema/Forager/Result/Insect.pm
Columns:
  record_id         INT PK AUTO_INCREMENT
  common_name       VARCHAR(255) NOT NULL
  scientific_name   VARCHAR(255)
  order_name        VARCHAR(100)   -- eg Hymenoptera, Coleoptera
  family_name       VARCHAR(100)
  genus             VARCHAR(100)
  species           VARCHAR(100)
  ecological_role   VARCHAR(100)   -- pollinator / pest / decomposer / predator / parasite
  plants_foraged    TEXT           -- plants visited for pollen/nectar
  plants_damaged    TEXT           -- plants this insect damages as pest
  habitat           TEXT
  lifecycle         TEXT           -- egg/larva/pupa/adult notes
  behavior          TEXT
  distribution      TEXT
  honey_production  TEXT           -- for bees: honey yield, quality notes
  pollination_notes TEXT
  pest_notes        TEXT
  beneficial_notes  TEXT
  image             VARCHAR(500)
  url               TEXT
  history           TEXT
  reference         TEXT
  sitename          VARCHAR(100) DEFAULT ''ENCY''
  username_of_poster VARCHAR(50)
  group_of_poster   VARCHAR(50)
  date_time_posted  VARCHAR(30)
  share             INT DEFAULT 0

--- TABLE: ency_disease_tb ---
Result file: Comserv/lib/Comserv/Model/Schema/Forager/Result/Disease.pm
Columns:
  record_id              INT PK AUTO_INCREMENT
  common_name            VARCHAR(255) NOT NULL
  scientific_name        VARCHAR(255)
  disease_type           VARCHAR(100)  -- infectious/genetic/nutritional/environmental/parasitic/autoimmune
  host_type              VARCHAR(100)  -- human/animal/plant/insect/multiple
  causative_agent        TEXT          -- virus, bacteria, fungus, parasite, toxin, etc.
  transmission           TEXT
  symptoms_description   TEXT          -- free-text description of symptoms
  diagnosis              TEXT
  treatment_conventional TEXT
  treatment_herbal       TEXT          -- herbal remedies and protocols
  prevention             TEXT
  prognosis              TEXT
  icd_code               VARCHAR(20)   -- ICD-10/11 code for human diseases
  distribution           TEXT          -- geographic prevalence
  image                  VARCHAR(500)
  url                    TEXT
  history                TEXT
  reference              TEXT
  sitename               VARCHAR(100) DEFAULT ''ENCY''
  username_of_poster     VARCHAR(50)
  group_of_poster        VARCHAR(50)
  date_time_posted       VARCHAR(30)
  share                  INT DEFAULT 0

--- TABLE: ency_symptom_tb ---
Result file: Comserv/lib/Comserv/Model/Schema/Forager/Result/Symptom.pm
Columns:
  record_id         INT PK AUTO_INCREMENT
  name              VARCHAR(255) NOT NULL   -- clinical name eg ''pyrexia''
  common_name       VARCHAR(255)            -- plain name eg ''fever''
  description       TEXT
  body_system       VARCHAR(100)  -- digestive/respiratory/neurological/cardiovascular/musculoskeletal/dermal/etc.
  severity          VARCHAR(50)   -- mild/moderate/severe/life-threatening
  acute_chronic     VARCHAR(20)   -- acute/chronic/both
  host_type         VARCHAR(100)  -- human/animal/plant/insect
  image             VARCHAR(500)
  url               TEXT
  reference         TEXT
  sitename          VARCHAR(100) DEFAULT ''ENCY''
  username_of_poster VARCHAR(50)
  group_of_poster   VARCHAR(50)
  date_time_posted  VARCHAR(30)
  share             INT DEFAULT 0

--- TABLE: ency_constituent_tb ---
Result file: Comserv/lib/Comserv/Model/Schema/Forager/Result/Constituent.pm
Columns:
  record_id             INT PK AUTO_INCREMENT
  name                  VARCHAR(255) NOT NULL
  common_name           VARCHAR(255)
  chemical_formula      VARCHAR(100)   -- eg C10H14O
  chemical_class        VARCHAR(100)   -- alkaloid/flavonoid/terpene/glycoside/phenol/steroid/etc.
  iupac_name            VARCHAR(500)
  cas_number            VARCHAR(50)    -- Chemical Abstracts Service number
  molecular_weight      DECIMAL(10,4)
  therapeutic_action    TEXT           -- what it does medicinally
  toxicity              TEXT           -- LD50, toxic dose, safety notes
  solubility            TEXT           -- water/alcohol/oil soluble
  found_in_herbs        TEXT           -- summary of herbs containing this compound
  found_in_foods        TEXT           -- foods containing this compound
  found_in_drugs        TEXT           -- pharmaceutical drugs using this compound
  pharmacological_effects TEXT
  research_notes        TEXT
  image                 VARCHAR(500)
  url                   TEXT
  reference             TEXT
  sitename              VARCHAR(100) DEFAULT ''ENCY''
  username_of_poster    VARCHAR(50)
  group_of_poster       VARCHAR(50)
  date_time_posted      VARCHAR(30)
  share                 INT DEFAULT 0

--- TABLE: ency_glossary_tb ---
Result file: Comserv/lib/Comserv/Model/Schema/Forager/Result/Glossary.pm
Columns:
  record_id       INT PK AUTO_INCREMENT
  term            VARCHAR(255) NOT NULL   -- eg ''astringent'', ''adaptogen''
  alternate_terms TEXT                    -- other names/spellings
  definition      TEXT NOT NULL
  category        VARCHAR(100)  -- botanical/medical/chemical/ecological/culinary/traditional
  context         TEXT          -- how/where the term is used in the encyclopedia
  etymology       TEXT          -- word origin
  examples        TEXT          -- example uses in context
  related_terms   TEXT          -- comma-separated related glossary terms
  url             TEXT
  sitename        VARCHAR(100) DEFAULT ''ENCY''
  username_of_poster VARCHAR(50)
  group_of_poster VARCHAR(50)
  date_time_posted VARCHAR(30)
  share           INT DEFAULT 0',
    160,
    'ENCY',
    'Shanta',
    'Shanta',
    'Requested',
    2,
    0,
    'Shanta',
    CURDATE(),
    'admin',
    @ency_project_id,
    NOW()
WHERE NOT EXISTS (
    SELECT 1 FROM `todo`
    WHERE `subject` = 'Phase 2: New Entities — Animals, Insects, Diseases, Symptoms, Constituents, Glossary'
    AND `project_id` = @ency_project_id
);

-- ----------------------------------------------------------------
-- Phase 3 — Cross-Referencing Junction Tables
-- ----------------------------------------------------------------
INSERT INTO `todo`
    (`sitename`, `start_date`, `due_date`, `subject`, `description`,
     `estimated_man_hours`, `project_code`, `developer`, `username_of_poster`,
     `status`, `priority`, `share`, `last_mod_by`, `last_mod_date`,
     `group_of_poster`, `project_id`, `date_time_posted`)
SELECT
    'ENCY',
    '2026-09-01',
    '2026-11-30',
    'Phase 3: Cross-Referencing — Junction Tables & Related Sections',
    'Branch ency-53b0. Implement all cross-reference junction tables linking encyclopedia entities to each other. All tables go in shanta_forager database. Result files in Comserv/lib/Comserv/Model/Schema/Forager/Result/. Admin runs schema compare for DDL. Add has_many/belongs_to/many_to_many relationships to all entity Result files.

--- TABLE: herb_constituent ---
Result file: HerbConstituent.pm
Columns:
  id              INT PK AUTO_INCREMENT
  herb_id         INT NOT NULL FK -> ency_herb_tb.record_id
  constituent_id  INT NOT NULL FK -> ency_constituent_tb.record_id
  quantity        DECIMAL(10,4)   -- amount per 100g dry weight
  unit            VARCHAR(30)     -- mg / mcg / % etc.
  plant_part      VARCHAR(100)    -- leaf/root/seed/flower/bark/whole
  notes           TEXT
UNIQUE KEY (herb_id, constituent_id, plant_part)

--- TABLE: herb_disease ---
Result file: HerbDisease.pm
Columns:
  id                INT PK AUTO_INCREMENT
  herb_id           INT NOT NULL FK -> ency_herb_tb.record_id
  disease_id        INT NOT NULL FK -> ency_disease_tb.record_id
  relationship_type VARCHAR(50)  -- treats / prevents / causes / contraindicated
  evidence_level    VARCHAR(50)  -- traditional / clinical / anecdotal
  notes             TEXT
UNIQUE KEY (herb_id, disease_id, relationship_type)

--- TABLE: herb_symptom ---
Result file: HerbSymptom.pm
Columns:
  id                INT PK AUTO_INCREMENT
  herb_id           INT NOT NULL FK -> ency_herb_tb.record_id
  symptom_id        INT NOT NULL FK -> ency_symptom_tb.record_id
  relationship_type VARCHAR(50)  -- relieves / causes / worsens
  notes             TEXT
UNIQUE KEY (herb_id, symptom_id, relationship_type)

--- TABLE: disease_symptom ---
Result file: DiseaseSymptom.pm
Columns:
  id          INT PK AUTO_INCREMENT
  disease_id  INT NOT NULL FK -> ency_disease_tb.record_id
  symptom_id  INT NOT NULL FK -> ency_symptom_tb.record_id
  frequency   VARCHAR(50)  -- always / common / occasional / rare
  notes       TEXT
UNIQUE KEY (disease_id, symptom_id)

--- TABLE: disease_animal ---
Result file: DiseaseAnimal.pm
Columns:
  id          INT PK AUTO_INCREMENT
  disease_id  INT NOT NULL FK -> ency_disease_tb.record_id
  animal_id   INT NOT NULL FK -> ency_animal_tb.record_id
  role        VARCHAR(50)  -- host / vector / reservoir
  notes       TEXT
UNIQUE KEY (disease_id, animal_id)

--- TABLE: disease_insect ---
Result file: DiseaseInsect.pm
Columns:
  id          INT PK AUTO_INCREMENT
  disease_id  INT NOT NULL FK -> ency_disease_tb.record_id
  insect_id   INT NOT NULL FK -> ency_insect_tb.record_id
  role        VARCHAR(50)  -- host / vector / carrier
  notes       TEXT
UNIQUE KEY (disease_id, insect_id)

--- TABLE: disease_herb (plant diseases) ---
Result file: DiseaseHerb.pm
Columns:
  id                INT PK AUTO_INCREMENT
  disease_id        INT NOT NULL FK -> ency_disease_tb.record_id (host_type=plant)
  herb_id           INT NOT NULL FK -> ency_herb_tb.record_id
  relationship_type VARCHAR(50)  -- afflicts / resistant / susceptible
  notes             TEXT
UNIQUE KEY (disease_id, herb_id)

--- TABLE: insect_herb ---
Result file: InsectHerb.pm
Columns:
  id               INT PK AUTO_INCREMENT
  insect_id        INT NOT NULL FK -> ency_insect_tb.record_id
  herb_id          INT NOT NULL FK -> ency_herb_tb.record_id
  interaction_type VARCHAR(50)  -- pollinates / damages / feeds_on / avoids
  notes            TEXT
UNIQUE KEY (insect_id, herb_id, interaction_type)

--- TABLE: animal_herb ---
Result file: AnimalHerb.pm
Columns:
  id               INT PK AUTO_INCREMENT
  animal_id        INT NOT NULL FK -> ency_animal_tb.record_id
  herb_id          INT NOT NULL FK -> ency_herb_tb.record_id
  interaction_type VARCHAR(50)  -- eats / medicates_self / avoids / pollinates
  notes            TEXT
UNIQUE KEY (animal_id, herb_id, interaction_type)

--- TABLE: constituent_disease ---
Result file: ConstituentDisease.pm
Columns:
  id                INT PK AUTO_INCREMENT
  constituent_id    INT NOT NULL FK -> ency_constituent_tb.record_id
  disease_id        INT NOT NULL FK -> ency_disease_tb.record_id
  relationship_type VARCHAR(50)  -- treats / inhibits / causes / marker_for
  evidence_level    VARCHAR(50)  -- traditional / clinical / anecdotal
  notes             TEXT
UNIQUE KEY (constituent_id, disease_id, relationship_type)

--- TABLE: constituent_symptom ---
Result file: ConstituentSymptom.pm
Columns:
  id                INT PK AUTO_INCREMENT
  constituent_id    INT NOT NULL FK -> ency_constituent_tb.record_id
  symptom_id        INT NOT NULL FK -> ency_symptom_tb.record_id
  relationship_type VARCHAR(50)  -- relieves / causes
  notes             TEXT
UNIQUE KEY (constituent_id, symptom_id, relationship_type)

--- TABLE: herb_category ---
Result file: HerbCategory.pm
Columns:
  id          INT PK AUTO_INCREMENT
  herb_id     INT NOT NULL FK -> ency_herb_tb.record_id
  category_id INT NOT NULL FK -> categories.category_id
UNIQUE KEY (herb_id, category_id)

ALSO: Add has_many/belongs_to/many_to_many declarations to all entity Result files. Add Related sections (Related Herbs, Related Diseases, etc.) to all entity detail view templates. Admin UI for managing cross-reference links on each entity edit form.',
    80,
    'ENCY',
    'Shanta',
    'Shanta',
    'Requested',
    3,
    0,
    'Shanta',
    CURDATE(),
    'admin',
    @ency_project_id,
    NOW()
WHERE NOT EXISTS (
    SELECT 1 FROM `todo`
    WHERE `subject` = 'Phase 3: Cross-Referencing — Junction Tables & Related Sections'
    AND `project_id` = @ency_project_id
);

-- ----------------------------------------------------------------
-- Phase 4 — AI Integration
-- ----------------------------------------------------------------
INSERT INTO `todo`
    (`sitename`, `start_date`, `due_date`, `subject`, `description`,
     `estimated_man_hours`, `project_code`, `developer`, `username_of_poster`,
     `status`, `priority`, `share`, `last_mod_by`, `last_mod_date`,
     `group_of_poster`, `project_id`, `date_time_posted`)
SELECT
    'ENCY',
    '2026-12-01',
    '2027-02-28',
    'Phase 4: AI Integration — Form Filling & Search Fallback',
    'Branch ency-53b0. Integrate AI chat into all ENCY entity forms and search. Uses existing Comserv::Controller::AI, Comserv::Model::Ollama, Comserv::Model::Grok infrastructure. No new DB tables required.

FEATURE 1 — Ask AI to fill form:
- Add ''Ask AI'' button to all ENCY add/edit forms (herbs, animals, insects, diseases, symptoms, constituents, glossary)
- Button opens AI chat panel (reuses existing AI controller chat endpoint)
- AI receives a system prompt: ''You are an encyclopedia assistant. The user will name an entity. Return a JSON object with fields matching the form: {field: value, ...}''
- JS parses the AI JSON response and populates form fields
- User reviews/edits before submitting
- Works for all 7 entity types

FEATURE 2 — AI search fallback:
- When a search returns zero local results, show ''No local results found.'' with link: ''Ask AI about [query]''
- Link opens AI chat with pre-filled prompt: ''Tell me about [query] as it relates to [entity type]''
- Result displayed in chat panel, not saved automatically

FEATURE 3 — Admin save AI result:
- In the AI response panel (when triggered from search fallback), show ''Save as new [Entity]'' button (admin role only)
- Button pre-fills the add form with the AI response
- Admin reviews and submits to create the DB entry
- Saves with username_of_poster = logged-in admin, source noted in reference field

TEMPLATE CHANGES: Add AI chat panel include and Ask AI button to all entity add/edit templates. No new PM files needed beyond JS/TT changes.',
    60,
    'ENCY',
    'Shanta',
    'Shanta',
    'Requested',
    4,
    0,
    'Shanta',
    CURDATE(),
    'admin',
    @ency_project_id,
    NOW()
WHERE NOT EXISTS (
    SELECT 1 FROM `todo`
    WHERE `subject` = 'Phase 4: AI Integration — Form Filling & Search Fallback'
    AND `project_id` = @ency_project_id
);

-- ----------------------------------------------------------------
-- Phase 5 — Global Search, Glossary Hyperlinking & Polish
-- ----------------------------------------------------------------
INSERT INTO `todo`
    (`sitename`, `start_date`, `due_date`, `subject`, `description`,
     `estimated_man_hours`, `project_code`, `developer`, `username_of_poster`,
     `status`, `priority`, `share`, `last_mod_by`, `last_mod_date`,
     `group_of_poster`, `project_id`, `date_time_posted`)
SELECT
    'ENCY',
    '2027-03-01',
    '2027-06-30',
    'Phase 5: Global Search, Glossary Hyperlinking & Polish',
    'Branch ency-53b0. Final integration, search, and UI polish. No new DB tables. Result file changes only if new indexes needed.

FEATURE 1 — Global cross-entity search (/ENCY/search):
- Single search box queries all entity types: herbs, animals, insects, diseases, symptoms, constituents, glossary
- Results grouped by entity type in tabbed or sectioned layout
- Each result links to its entity detail page
- Search covers: name fields, description, therapeutic_action, common_name

FEATURE 2 — Glossary term hyperlinking:
- When rendering herb, disease, animal, insect detail pages, scan description/action fields for glossary terms
- Auto-link matched terms to their /ENCY/glossary/[term] page
- Use a TT macro or Perl helper in ENCYModel to process text
- Terms matched case-insensitively, longest match first (to avoid partial matches)

FEATURE 3 — Navigation update:
- Update TopDropListENCY.tt (or equivalent) to include all entity type sections
- Ensure ENCY site nav shows: Herbs | Animals | Insects | Diseases | Symptoms | Constituents | Glossary | Search

FEATURE 4 — Pagination:
- All list views (BotanicalNameView, AnimalList, InsectList, etc.) to support pagination
- Page size: 50 records default
- Use DBIC rows/page/offset parameters

FEATURE 5 — Performance indexes (schema change via Result file annotation):
- ency_herb_tb: index on botanical_name, key_name
- ency_animal_tb: index on common_name, scientific_name
- ency_insect_tb: index on common_name, scientific_name, ecological_role
- ency_disease_tb: index on common_name, host_type
- ency_symptom_tb: index on name, body_system
- ency_constituent_tb: index on name, chemical_class
- ency_glossary_tb: index on term',
    40,
    'ENCY',
    'Shanta',
    'Shanta',
    'Requested',
    5,
    0,
    'Shanta',
    CURDATE(),
    'admin',
    @ency_project_id,
    NOW()
WHERE NOT EXISTS (
    SELECT 1 FROM `todo`
    WHERE `subject` = 'Phase 5: Global Search, Glossary Hyperlinking & Polish'
    AND `project_id` = @ency_project_id
);

-- ============================================================
-- Verify: show what was created
-- ============================================================
SELECT id, name, project_code, sitename, status, estimated_man_hours
FROM `projects`
WHERE `project_code` = 'ENCY';

SELECT record_id, subject, status, priority, due_date
FROM `todo`
WHERE `project_id` = @ency_project_id
ORDER BY priority;
