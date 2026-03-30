-- HealthPlanning Feature — Project & Todo Seed
-- Developer: CSC  |  Revenue Site: Shanta SiteName
-- Project Code: HLTHPLAN-SHANTA
--
-- Inserts the HealthPlanning project (and sub-project) plus implementation todos
-- into the existing planning system (projects + todo tables in ENCY DB).
-- Safe to run once; uses INSERT IGNORE to avoid duplicates.

-- ---------------------------------------------------------------------------
-- Main HealthPlanning project
-- ---------------------------------------------------------------------------
INSERT IGNORE INTO projects
    (name, description, project_code, client_name, developer_name, sitename,
     status, start_date, date_time_posted, username_of_poster, group_of_poster)
VALUES (
    'HealthPlanning Feature',
    'Member health planning module with AI-guided symptom intake, disease mapping, natural-health practitioner teams, diet/herb/exercise plans, and inventory integration. Billing: CSC. Revenue: Shanta SiteName.',
    'HLTHPLAN-SHANTA',
    'Shanta SiteName',
    'CSC',
    'CSC',
    'active',
    CURDATE(),
    NOW(),
    'system',
    'admin'
);

SET @hp_project_id = LAST_INSERT_ID();

-- ---------------------------------------------------------------------------
-- Sub-project: ENCY Tables
-- ---------------------------------------------------------------------------
INSERT IGNORE INTO projects
    (name, description, project_code, client_name, developer_name, sitename,
     status, start_date, parent_id, date_time_posted, username_of_poster, group_of_poster)
VALUES (
    'HealthPlanning — ENCY Tables',
    'New ENCY database tables required by the HealthPlanning feature: health_symptoms, health_diseases, health_symptom_disease_map, health_practitioner_types, health_disease_practitioners, health_member_plans, health_diet_plans, health_meal_plans, health_herb_prescriptions, health_exercise_plans, health_inventory_items.',
    'HLTHPLAN-ENCY',
    'Shanta SiteName',
    'CSC',
    'CSC',
    'active',
    CURDATE(),
    @hp_project_id,
    NOW(),
    'system',
    'admin'
);

SET @ency_sub_project_id = LAST_INSERT_ID();

-- ---------------------------------------------------------------------------
-- Implementation Todos linked to main HealthPlanning project
-- ---------------------------------------------------------------------------

INSERT INTO todo
    (subject, description, project_id, project_code, sitename, status, priority,
     start_date, due_date, date_time_posted, username_of_poster, group_of_poster,
     share, last_mod_by, last_mod_date, user_id)
VALUES
(
    'Step 1: Create DB Schema Result Classes',
    'Create 11 DBIx::Class Result classes for health planning tables in Comserv/lib/Comserv/Model/Schema/Ency/Result/. See health_planning_schema.sql and requirements.md.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'completed',
    1,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 7 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 2: Create SQL Migration',
    'Write and test Comserv/sql/health_planning_schema.sql — CREATE TABLE IF NOT EXISTS for all 11 health planning tables.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'completed',
    1,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 7 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 3: Create HealthPlanning Model',
    'Implement Comserv::Model::HealthPlanning with methods: get_symptoms_by_query, map_symptoms_to_diseases, get_recommended_practitioners, create_member_plan, get_plan_with_details, check_inventory_for_meal, store_ai_finding_in_ency.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'completed',
    1,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 14 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 4: Create HealthPlanning Controller',
    'Implement Comserv::Controller::HealthPlanning with routes: index, intake, symptom_search (AJAX), plan_view, plan_create, diet_plan, herb_plan, exercise_plan, inventory, inventory_update, ai_chat (AJAX).',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'completed',
    1,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 14 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 5: Create Templates',
    'Create 7 Template Toolkit views under Comserv/root/HealthPlanning/: index.tt, intake.tt (with AI chat panel + AJAX symptom search), plan_view.tt, diet_plan.tt, herb_plan.tt, exercise_plan.tt, inventory.tt.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'completed',
    1,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 21 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 6: Navigation Wiring',
    'Add HealthPlanning links to Navigation/TopDropListMember.tt and admin/admin_map.tt. Verify Catalyst auto-discovery of the controller.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'in_progress',
    2,
    CURDATE(),
    DATE_ADD(CURDATE(), INTERVAL 21 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 7: AI Chat Integration Testing',
    'Test the /HealthPlanning/ai_chat AJAX endpoint: Ollama query → ENCY WebSearchResult storage. Verify health-focused system prompt. Test fallback behaviour when Ollama is unavailable.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'pending',
    2,
    DATE_ADD(CURDATE(), INTERVAL 7 DAY),
    DATE_ADD(CURDATE(), INTERVAL 28 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 8: Inventory Integration Testing',
    'Populate sample inventory (herbs + foods). Test check_inventory_for_meal against meal plans. Verify low-stock highlighting and reorder suggestions in inventory.tt.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'pending',
    2,
    DATE_ADD(CURDATE(), INTERVAL 7 DAY),
    DATE_ADD(CURDATE(), INTERVAL 28 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 9: Seed Symptom & Disease Data',
    'Populate health_symptoms, health_diseases, health_symptom_disease_map, health_practitioner_types, health_disease_practitioners with initial dataset covering common health conditions.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'pending',
    3,
    DATE_ADD(CURDATE(), INTERVAL 14 DAY),
    DATE_ADD(CURDATE(), INTERVAL 42 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 10: Billing & Revenue Configuration',
    'Configure project billing: CSC invoices for development. Set up revenue attribution so Shanta SiteName receives revenue when other sites adopt the HealthPlanning add-on feature.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'pending',
    3,
    DATE_ADD(CURDATE(), INTERVAL 21 DAY),
    DATE_ADD(CURDATE(), INTERVAL 60 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
),
(
    'Step 11: QA & User Testing',
    'End-to-end test: member selects symptoms → disease mapped → plan created → diet/herb/exercise sub-plans filled in → inventory checked → AI chat tested → plan viewed. Fix all bugs.',
    @hp_project_id,
    'HLTHPLAN-SHANTA',
    'CSC',
    'pending',
    3,
    DATE_ADD(CURDATE(), INTERVAL 28 DAY),
    DATE_ADD(CURDATE(), INTERVAL 60 DAY),
    NOW(),
    'system',
    'admin',
    0,
    'system',
    CURDATE(),
    1
);
