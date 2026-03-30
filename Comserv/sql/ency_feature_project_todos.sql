-- ============================================================
-- ENCY Encyclopedia Feature — Project & Todo Registration
-- Branch: ency-53b0
-- Date: 2026-03-30
-- Run against: ency database
-- ============================================================
-- This script registers the ENCY Encyclopedia development work
-- in the project tracking and todo system so it can be
-- coordinated with other branches.
-- ============================================================

USE `ency`;

-- ============================================================
-- 1. PARENT PROJECT: Encyclopedia of Biological Life (ENCY)
-- ============================================================
-- Uses INSERT IGNORE to be safe if already exists by name.
-- Check first: SELECT id FROM projects WHERE project_code = 'ENCY' AND sitename = 'ENCY';

INSERT INTO `projects`
    (`name`, `description`, `start_date`, `end_date`, `status`,
     `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
     `developer_name`, `client_name`, `sitename`, `comments`,
     `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`)
SELECT
    'Encyclopedia of Biological Life',
    'The ENCY feature provides a comprehensive, publicly browsable reference database of biological life. Branch: ency-53b0. Covers herbs, animals, insects, diseases, symptoms, constituents, glossary terms, cross-referencing between all entities, and AI-assisted data entry and search fallback.',
    '2026-03-30',
    '2027-06-30',
    'In-Process',
    0,
    'ENCY',
    50,
    400,
    'Shanta',
    'ENCY',
    'ENCY',
    'Branch: ency-53b0. PRD in .zenflow/tasks/ency-53b0/requirements.md. Phased delivery: Phase1=Herbs, Phase2=New Entities, Phase3=Cross-Refs, Phase4=AI, Phase5=Global Search.',
    'Shanta',
    'admin',
    NOW(),
    NULL
WHERE NOT EXISTS (
    SELECT 1 FROM `projects`
    WHERE `project_code` = 'ENCY' AND `sitename` = 'ENCY'
);

-- ============================================================
-- 2. PHASE TODO ITEMS
-- Linked to the ENCY project created above.
-- ============================================================

-- Helper: get the ENCY project id
SET @ency_project_id = (
    SELECT `id` FROM `projects`
    WHERE `project_code` = 'ENCY' AND `sitename` = 'ENCY'
    ORDER BY `id` DESC LIMIT 1
);

-- Phase 1 — Herb Foundation
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
    'Branch ency-53b0. Fix all known bugs in existing herb implementation: mode inconsistency in HerbView.tt, missing forward() calls, wrong logging signature in add_herb. Standardize all herb templates to coding standards (META blocks, theme CSS, flash messages). Complete fully functional herb CRUD. Fix References and Category result class schemas.',
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

-- Phase 2 — New Entity Databases
INSERT INTO `todo`
    (`sitename`, `start_date`, `due_date`, `subject`, `description`,
     `estimated_man_hours`, `project_code`, `developer`, `username_of_poster`,
     `status`, `priority`, `share`, `last_mod_by`, `last_mod_date`,
     `group_of_poster`, `project_id`, `date_time_posted`)
SELECT
    'ENCY',
    '2026-05-01',
    '2026-08-31',
    'Phase 2: New Entity Databases — Animals, Insects, Diseases, Symptoms, Constituents, Glossary',
    'Branch ency-53b0. Implement 6 new encyclopedia entity types: Animals, Insects, Diseases (human/animal/plant/insect), Symptoms, Constituents (mapped to herbs/foods/drugs), Glossary of terms. Each requires DB table(s), DBIx::Class result class, ENCYModel methods, ENCY controller actions, and TT templates compliant with coding standards.',
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
    WHERE `subject` = 'Phase 2: New Entity Databases — Animals, Insects, Diseases, Symptoms, Constituents, Glossary'
    AND `project_id` = @ency_project_id
);

-- Phase 3 — Cross-Referencing
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
    'Branch ency-53b0. Implement all cross-reference junction tables: HerbConstituent, HerbDisease, HerbSymptom, DiseaseSymptom, DiseaseAnimal, DiseaseInsect, InsectHerb, AnimalHerb, ConstituentDisease. Add Related sections to all entity detail pages. Admin UI for managing cross-reference links.',
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

-- Phase 4 — AI Integration
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
    'Branch ency-53b0. Integrate AI chat into ENCY: (1) Ask AI to fill form button on all add/edit forms — opens AI chat, parses response into form fields. (2) AI search fallback — zero local results shows Ask AI link. (3) Admin Save AI result workflow — promote AI response to a new DB entry. Uses existing Comserv::Controller::AI and Comserv::Model::Ollama/Grok infrastructure.',
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

-- Phase 5 — Global Search & Polish
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
    'Branch ency-53b0. (1) Global cross-entity search returning categorized results (herbs, animals, insects, diseases, etc.). (2) Glossary term hyperlinking — technical terms in herb/disease descriptions auto-link to their glossary entry. (3) Update TopDropListENCY.tt navigation to include all sections. (4) Pagination for large result sets. (5) Performance indexing.',
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
