-- =============================================================================
-- ENCY Data Import: Forager → Ency Database
-- Description: Seeds ency DB tables with verified legacy data from forager DB.
-- Run as: mysql -u <user> -p ency < ency_import_from_forager.sql
-- Prerequisites: Both `ency` and `forager` schemas accessible to the DB user.
--                New entity tables must already exist (run schema-compare first).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. HERBS: forager.ency_herb_tb → ency.ency_herb_tb
--    Maps legacy columns to current schema. Skips duplicates on botanical_name.
-- ---------------------------------------------------------------------------
INSERT IGNORE INTO ency.ency_herb_tb (
    botanical_name,
    common_names,
    parts_used,
    therapeutic_action,
    medical_uses,
    constituents,
    administration,
    dosage,
    preparation,
    formulas,
    contra_indications,
    cultivation,
    harvest,
    distribution,
    history,
    reference,
    image,
    url,
    stem,
    leaves,
    flowers,
    fruit,
    root,
    taste,
    odour,
    solvents,
    chinese,
    culinary,
    non_med,
    vetrinary,
    sister_plants,
    nectar,
    pollen,
    pollinator,
    pollennotes,
    nectarnotes,
    homiopathic,
    ident_character,
    comments,
    username_of_poster,
    group_of_poster,
    date_time_posted,
    share,
    sitename
)
SELECT
    botanical_name,
    common_names,
    parts_used,
    therapeutic_action,
    medical_uses,
    constituents,
    administration,
    dosage,
    preparation,
    formulas,
    contra_indications,
    cultivation,
    harvest,
    distribution,
    history,
    reference,
    image,
    url,
    stem,
    leaves,
    flowers,
    fruit,
    root,
    taste,
    odour,
    solvents,
    chinese,
    culinary,
    non_med,
    vetrinary,
    sister_plants,
    nectar,
    pollen,
    pollinator,
    pollennotes,
    nectarnotes,
    homiopathic,
    ident_character,
    comments,
    username_of_poster,
    group_of_poster,
    date_time_posted,
    COALESCE(share, 0),
    'ENCY'
FROM forager.ency_herb_tb
WHERE botanical_name IS NOT NULL
  AND botanical_name != '';

-- ---------------------------------------------------------------------------
-- 2. PAGES: forager.page_tb → ency.page_tb
--    Import any ENCY-related page records from the forager DB.
-- ---------------------------------------------------------------------------
INSERT IGNORE INTO ency.page_tb (
    page_name,
    page_title,
    page_content,
    sitename,
    username_of_poster,
    group_of_poster,
    date_time_posted
)
SELECT
    page_name,
    page_title,
    page_content,
    sitename,
    username_of_poster,
    group_of_poster,
    date_time_posted
FROM forager.page_tb
WHERE sitename = 'ENCY'
  AND page_name IS NOT NULL
ON DUPLICATE KEY UPDATE
    page_content = VALUES(page_content),
    date_time_posted = VALUES(date_time_posted);

-- ---------------------------------------------------------------------------
-- 3. REPORT: counts after import
-- ---------------------------------------------------------------------------
SELECT 'ency_herb_tb'  AS target_table, COUNT(*) AS total_rows FROM ency.ency_herb_tb
UNION ALL
SELECT 'page_tb (ENCY)',                 COUNT(*) FROM ency.page_tb WHERE sitename = 'ENCY';
