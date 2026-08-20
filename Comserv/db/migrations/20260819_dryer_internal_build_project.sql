-- Migration: 20260819_dryer_internal_build_project.sql
-- Purpose: Create the owning Project + phase sub-projects + re-audit
--          todo for the "Dryer — Internal 3D Build" import/print plan.
--          Mirrors 20260410_3d_printing_todo.sql insert pattern.
-- Note: only columns that exist in the live DB are used. projects has several
--       NOT NULL no-default columns; all are supplied explicitly below.
-- Author: Hermes Agent
-- Date: 2026-08-19

-- ============================================================
-- Parent project: Dryer — Internal 3D Build (not for sale)
-- ============================================================
INSERT INTO projects (
    record_id, name, description, status, project_code, sitename,
    project_size, estimated_man_hours, developer_name, client_name, comments,
    username_of_poster, group_of_poster, date_time_posted, start_date, end_date
)
SELECT
    99001,
    'Dryer — Internal 3D Build',
    'Import downloaded STL+PDF files for the new dryer as an internal (not-for-sale) 3D build: parent assembly item, per-part inventory + BOM, auto print-queue, auto stock-in on completion. See /Documentation/DryerProjectImportPlan.',
    'in_progress',
    'DRYER-INT',
    'CSC',
    0, 0, 'system', 'internal', '',
    'system', 'admin', NOW(), CURDATE(), '2099-12-31'
WHERE NOT EXISTS (
    SELECT 1 FROM projects WHERE project_code = 'DRYER-INT'
);

SET @parent_id = (SELECT id FROM projects WHERE project_code = 'DRYER-INT');

-- ============================================================
-- Phase sub-projects (RULE P1: phases are sub-projects, not single todos)
-- ============================================================
INSERT INTO projects (
    record_id, name, description, status, project_code, sitename,
    parent_id, project_size, estimated_man_hours, developer_name, client_name, comments,
    username_of_poster, group_of_poster, date_time_posted, start_date, end_date
)
SELECT
    99002,
    'Dryer Phase 1 — Gather & select files',
    'Locate downloads; select STL+PDF via FileManager; confirm BOM quantities per part.',
    'in_progress', 'DRYER-INT-P1', 'CSC', @parent_id, 0, 0, 'system', 'internal', '',
    'system', 'admin', NOW(), CURDATE(), '2099-12-31'
WHERE NOT EXISTS (SELECT 1 FROM projects WHERE project_code = 'DRYER-INT-P1');

INSERT INTO projects (
    record_id, name, description, status, project_code, sitename,
    parent_id, project_size, estimated_man_hours, developer_name, client_name, comments,
    username_of_poster, group_of_poster, date_time_posted, start_date, end_date
)
SELECT
    99003,
    'Dryer Phase 2 — Run import',
    'Create parent assembly item; run DryerImport dry-run; approve; verify models+inventory+BOM+queue rows.',
    'in_progress', 'DRYER-INT-P2', 'CSC', @parent_id, 0, 0, 'system', 'internal', '',
    'system', 'admin', NOW(), CURDATE(), '2099-12-31'
WHERE NOT EXISTS (SELECT 1 FROM projects WHERE project_code = 'DRYER-INT-P2');

INSERT INTO projects (
    record_id, name, description, status, project_code, sitename,
    parent_id, project_size, estimated_man_hours, developer_name, client_name, comments,
    username_of_poster, group_of_poster, date_time_posted, start_date, end_date
)
SELECT
    99004,
    'Dryer Phase 3 — Print queue execution',
    'Assign jobs to printers; print; on completion confirm auto stock-in of finished parts.',
    'in_progress', 'DRYER-INT-P3', 'CSC', @parent_id, 0, 0, 'system', 'internal', '',
    'system', 'admin', NOW(), CURDATE(), '2099-12-31'
WHERE NOT EXISTS (SELECT 1 FROM projects WHERE project_code = 'DRYER-INT-P3');

INSERT INTO projects (
    record_id, name, description, status, project_code, sitename,
    parent_id, project_size, estimated_man_hours, developer_name, client_name, comments,
    username_of_poster, group_of_poster, date_time_posted, start_date, end_date
)
SELECT
    99005,
    'Dryer Phase 4 — Assembly & verification',
    'Confirm all parts received; assemble dryer; attach build PDF to final record; mark project done.',
    'in_progress', 'DRYER-INT-P4', 'CSC', @parent_id, 0, 0, 'system', 'internal', '',
    'system', 'admin', NOW(), CURDATE(), '2099-12-31'
WHERE NOT EXISTS (SELECT 1 FROM projects WHERE project_code = 'DRYER-INT-P4');

-- ============================================================
-- Re-audit todo (RULE P2 analogue: keep the plan doc from going stale)
-- status 1 = new/open; priority 5
-- ============================================================
INSERT INTO todo (
    sitename, subject, description, status, priority,
    project_code, username_of_poster, group_of_poster,
    date_time_posted, last_mod_by, last_mod_date, share,
    parent_todo, start_date, due_date,
    estimated_man_hours, accumulative_time, user_id, project_id
)
SELECT
    'CSC',
    'Re-audit Dryer internal-build plan + import automation',
    'Quarterly re-check that DryerProjectImportPlan.tt matches the live printing_3d_models / printing_3d_jobs / inventory_item_bom schema and the DryerImport automation still works end-to-end.',
    1, 5,
    'DRYER-INT', 'system', 'admin',
    NOW(), 'system', NOW(), 0, '',
    CURDATE(), DATE_ADD(CURDATE(), INTERVAL 90 DAY),
    0, '00:00:00', 0, 0
WHERE NOT EXISTS (
    SELECT 1 FROM todo WHERE subject = 'Re-audit Dryer internal-build plan + import automation'
);
