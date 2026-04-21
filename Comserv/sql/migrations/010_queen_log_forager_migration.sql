-- Queen Log Forager Data Migration Plan
-- File: 010_queen_log_forager_migration.sql
-- DB Project: 219 (QueenLogModel) under Apiary Management System (91)
-- Todos: 797 (ApisQueensTb → queens), 798 (ApisQueenLogTb → inspections + queen_events)
--
-- SOURCE: Forager DB — apis_queens_tb, apis_queen_log_tb
-- TARGET: Ency DB — queens, queen_events, inspections, queen_hive_assignments
--
-- PREREQUISITES:
--   1. Migration 009_queen_log_schema.sql applied (queens, queen_events, queen_hive_assignments tables exist)
--   2. yards table populated with yards matching Forager yard_code values
--   3. hives table populated with hives matching Forager pallet_code/queen_code references
--   4. Both Forager and Ency DBs accessible from same migration session
--
-- VERIFICATION:
--   After each step, run the COUNT checks at the bottom of this file.

-- ============================================================================
-- TODO 797: Migrate ApisQueensTb → queens
-- ============================================================================
--
-- FIELD MAPPING:
--   apis_queens_tb.queen_code      → queens.tag_number
--   apis_queens_tb.queen_name      → queens.breed  (closest semantic match; name often contains breed info)
--   apis_queens_tb.queen_colour    → queens.color_marking
--   apis_queens_tb.parent          → queens.parent_queen_id  (requires lookup by tag_number after insert)
--   apis_queens_tb.pallet_code     → queens.current_pallet_id (requires hive/pallet lookup)
--   apis_queens_tb.yard_code       → queens.current_yard_id  (requires yard lookup)
--   apis_queens_tb.status          → queens.status (map: 'active'→'active', others→'inactive')
--   apis_queens_tb.date            → queens.birth_date (parse varchar date)
--   apis_queens_tb.date_time_posted → queens.created_at
--   apis_queens_tb.username_of_poster → queens.created_by
--   apis_queens_tb.comments        → queens.comments
--   apis_queens_tb.client_name     → queens.origin (beekeeper/client name as origin note)
--   apis_queens_tb.sitename        → (used to filter: only migrate sitename = 'BMaster')
--
-- NOTE: box_number, group_of_poster, location, record_id are Forager-internal
--       and do not map to canonical queen fields. Discard after migration.

-- Step 1: Insert base queen records (run on ency DB with Forager accessible via federated link or after export)
INSERT INTO queens (
    tag_number,
    breed,
    color_marking,
    origin,
    status,
    birth_date,
    comments,
    created_by,
    created_at
)
SELECT
    aqt.queen_code,
    aqt.queen_name,
    aqt.queen_colour,
    aqt.client_name,
    CASE
        WHEN aqt.status = 'active' THEN 'active'
        WHEN aqt.status = 'dead'   THEN 'dead'
        WHEN aqt.status = 'sold'   THEN 'sold'
        ELSE 'inactive'
    END,
    CASE
        WHEN aqt.date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(aqt.date, '%Y-%m-%d')
        WHEN aqt.date REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(aqt.date, '%d/%m/%Y')
        ELSE NULL
    END,
    aqt.comments,
    aqt.username_of_poster,
    CASE
        WHEN aqt.date_time_posted REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN STR_TO_DATE(LEFT(aqt.date_time_posted, 19), '%Y-%m-%d %H:%i:%s')
        ELSE CURRENT_TIMESTAMP
    END
FROM forager.apis_queens_tb aqt
WHERE aqt.sitename = 'BMaster'
ON DUPLICATE KEY UPDATE
    color_marking = VALUES(color_marking),
    origin = VALUES(origin);

-- Step 2: Resolve parent_queen_id self-references
UPDATE queens q
JOIN queens parent_q ON parent_q.tag_number = (
    SELECT aqt.parent FROM forager.apis_queens_tb aqt WHERE aqt.queen_code = q.tag_number LIMIT 1
)
SET q.parent_queen_id = parent_q.id
WHERE q.parent_queen_id IS NULL;

-- Step 3: Resolve current_yard_id from yard_code
UPDATE queens q
JOIN yards y ON y.code = (
    SELECT aqt.yard_code FROM forager.apis_queens_tb aqt WHERE aqt.queen_code = q.tag_number LIMIT 1
)
SET q.current_yard_id = y.id
WHERE q.current_yard_id IS NULL;

-- Step 4: Create queen_hive_assignments from pallet_code lookups
-- (assumes hives.pallet_code column exists and is populated from Forager hive data)
INSERT INTO queen_hive_assignments (queen_id, hive_id, yard_id, assigned_date, reason, created_by)
SELECT
    q.id,
    h.id,
    h.yard_id,
    COALESCE(q.birth_date, CURDATE()),
    'forager_migration',
    'migration'
FROM queens q
JOIN forager.apis_queens_tb aqt ON aqt.queen_code = q.tag_number
JOIN hives h ON h.pallet_code = aqt.pallet_code
WHERE aqt.status = 'active'
  AND NOT EXISTS (
      SELECT 1 FROM queen_hive_assignments qha WHERE qha.queen_id = q.id AND qha.hive_id = h.id
  );

-- ============================================================================
-- TODO 798: Migrate ApisQueenLogTb → inspections + queen_events
-- ============================================================================
--
-- FIELD MAPPING — inspections:
--   apis_queen_log_tb.start_date       → inspections.inspection_date
--   apis_queen_log_tb.start_time       → inspections.start_time
--   apis_queen_log_tb.end_time         → inspections.end_time
--   apis_queen_log_tb.queen_code       → inspections.queen_id (lookup)
--   apis_queen_log_tb.pallet_code      → inspections.hive_id (lookup via hives.pallet_code)
--   apis_queen_log_tb.username_of_poster → inspections.inspector
--   apis_queen_log_tb.comments         → inspections.general_notes
--   apis_queen_log_tb.details          → inspections.action_required
--   apis_queen_log_tb.abstract         → prepended to general_notes
--   apis_queen_log_tb.status           → inspections.overall_status (map below)
--
-- STATUS MAPPING:
--   'good' / 'excellent'  → overall_status = 'good' / 'excellent'
--   'ok'                  → overall_status = 'good'
--   'problem' / 'bad'     → overall_status = 'poor'
--   default               → overall_status = 'good'
--
-- BOX DATA → inspection_details rows (one per box):
--   box_1_*, box_2_*, box_x_* → InspectionDetail records (separate INSERT)
--
-- HONEY DATA → honey_harvests rows (if honey_removed > 0):
--   honey_removed, honey_added → honey_harvests table
--
-- FIELD MAPPING — queen_events:
--   If honey_removed > 0: create 'treated' event with note about harvest
--   If brood_given > 0: create 'moved' event with note
--   (queues up based on presence of significant activity fields)

-- Step 1: Insert inspection records
INSERT INTO inspections (
    hive_id,
    inspection_date,
    start_time,
    end_time,
    inspector,
    inspection_type,
    overall_status,
    queen_id,
    general_notes,
    action_required,
    created_at
)
SELECT
    h.id,
    CASE
        WHEN aql.start_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(aql.start_date, '%Y-%m-%d')
        WHEN aql.start_date REGEXP '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' THEN STR_TO_DATE(aql.start_date, '%d/%m/%Y')
        ELSE CURDATE()
    END,
    CASE
        WHEN aql.start_time > 0 THEN SEC_TO_TIME(FLOOR(aql.start_time) * 3600 + ROUND((aql.start_time - FLOOR(aql.start_time)) * 60) * 60)
        ELSE NULL
    END,
    CASE
        WHEN aql.end_time > 0 THEN STR_TO_DATE(aql.end_time, '%H:%i')
        ELSE NULL
    END,
    aql.username_of_poster,
    'routine',
    CASE
        WHEN aql.status IN ('excellent') THEN 'excellent'
        WHEN aql.status IN ('good', 'ok', '') THEN 'good'
        WHEN aql.status IN ('fair') THEN 'fair'
        WHEN aql.status IN ('problem', 'poor', 'bad') THEN 'poor'
        WHEN aql.status IN ('critical', 'emergency') THEN 'critical'
        ELSE 'good'
    END,
    q.id,
    CONCAT_WS(' | ', NULLIF(aql.abstract, ''), NULLIF(aql.comments, '')),
    NULLIF(aql.details, ''),
    CASE
        WHEN aql.date_time_posted REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN STR_TO_DATE(LEFT(aql.date_time_posted, 19), '%Y-%m-%d %H:%i:%s')
        ELSE CURRENT_TIMESTAMP
    END
FROM forager.apis_queen_log_tb aql
JOIN hives h ON h.pallet_code = aql.pallet_code
LEFT JOIN queens q ON q.tag_number = aql.queen_code
WHERE aql.sitename = 'BMaster';

-- Step 2: Insert queen_events for significant log entries
-- a) Brood additions → 'moved' event (brood frame movement between hives)
INSERT INTO queen_events (queen_id, event_type, event_date, hive_id, notes, created_by)
SELECT
    q.id,
    'moved',
    CASE
        WHEN aql.start_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(aql.start_date, '%Y-%m-%d')
        ELSE CURDATE()
    END,
    h.id,
    CONCAT('Brood given: ', aql.brood_given, ' (migrated from Forager record ', aql.record_id, ')'),
    'migration'
FROM forager.apis_queen_log_tb aql
JOIN hives h ON h.pallet_code = aql.pallet_code
JOIN queens q ON q.tag_number = aql.queen_code
WHERE aql.sitename = 'BMaster'
  AND aql.brood_given IS NOT NULL
  AND aql.brood_given != ''
  AND aql.brood_given != '0';

-- b) Status changes to dead/superseded → lifecycle events
INSERT INTO queen_events (queen_id, event_type, event_date, hive_id, notes, created_by)
SELECT
    q.id,
    CASE
        WHEN aql.status = 'dead' THEN 'dead'
        WHEN aql.status = 'superseded' THEN 'superseded'
        WHEN aql.status = 'replaced' THEN 'replaced'
        ELSE 'inspected'
    END,
    CASE
        WHEN aql.start_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN STR_TO_DATE(aql.start_date, '%Y-%m-%d')
        ELSE CURDATE()
    END,
    h.id,
    CONCAT('Status recorded as: ', aql.status, ' (migrated from Forager record ', aql.record_id, ')'),
    'migration'
FROM forager.apis_queen_log_tb aql
JOIN hives h ON h.pallet_code = aql.pallet_code
JOIN queens q ON q.tag_number = aql.queen_code
WHERE aql.sitename = 'BMaster'
  AND aql.status IN ('dead', 'superseded', 'replaced');

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Count migrated queens
-- SELECT 'queens migrated' AS label, COUNT(*) AS cnt FROM queens WHERE created_by != 'migration' OR created_by IS NULL
-- UNION ALL
-- SELECT 'forager queens', COUNT(*) FROM forager.apis_queens_tb WHERE sitename = 'BMaster';

-- Count migrated inspections
-- SELECT 'inspections migrated' AS label, COUNT(*) AS cnt FROM inspections
-- UNION ALL
-- SELECT 'forager log entries', COUNT(*) FROM forager.apis_queen_log_tb WHERE sitename = 'BMaster';

-- Count queen_events created
-- SELECT event_type, COUNT(*) FROM queen_events GROUP BY event_type ORDER BY COUNT(*) DESC;

-- Count queen_hive_assignments
-- SELECT 'active assignments', COUNT(*) FROM queen_hive_assignments WHERE removed_date IS NULL;

-- Orphaned log entries (pallet_code not found in hives)
-- SELECT COUNT(*) AS orphaned FROM forager.apis_queen_log_tb aql
-- WHERE aql.sitename = 'BMaster' AND NOT EXISTS (SELECT 1 FROM hives h WHERE h.pallet_code = aql.pallet_code);
