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
-- 2. CONSTITUENTS: extracted from forager.ency_herb_tb.constituents text field
--    Strategy: each comma/semicolon-separated token in the constituents column
--    becomes a row in ency_constituent_tb, deduplicated by name.
--    Then herb_constituent junction rows link each herb to its constituents.
--
--    STEP A: seed unique constituent names into ency_constituent_tb.
--    We use a stored procedure to split the text field token-by-token.
-- ---------------------------------------------------------------------------

DROP PROCEDURE IF EXISTS ency_import_constituents;

DELIMITER $$
CREATE PROCEDURE ency_import_constituents()
BEGIN
    DECLARE done        INT DEFAULT FALSE;
    DECLARE herb_id     INT;
    DECLARE raw_text    TEXT;
    DECLARE token       VARCHAR(500);
    DECLARE delim_pos   INT;
    DECLARE remainder   TEXT;

    DECLARE herb_cur CURSOR FOR
        SELECT h.record_id, h.constituents
        FROM ency.ency_herb_tb h
        WHERE h.constituents IS NOT NULL
          AND TRIM(h.constituents) != '';

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    OPEN herb_cur;

    read_loop: LOOP
        FETCH herb_cur INTO herb_id, raw_text;
        IF done THEN LEAVE read_loop; END IF;

        -- Normalise separators: semicolons → commas
        SET remainder = REPLACE(raw_text, ';', ',');

        token_loop: LOOP
            SET delim_pos = LOCATE(',', remainder);

            IF delim_pos = 0 THEN
                SET token = TRIM(remainder);
                SET remainder = '';
            ELSE
                SET token = TRIM(SUBSTRING(remainder, 1, delim_pos - 1));
                SET remainder = TRIM(SUBSTRING(remainder, delim_pos + 1));
            END IF;

            -- Skip empty / very short tokens (likely noise)
            IF LENGTH(token) > 2 THEN
                -- Insert constituent if not already present (match on name)
                INSERT IGNORE INTO ency.ency_constituent_tb (name, sitename, username_of_poster, date_time_posted)
                VALUES (token, 'ENCY', 'import', NOW());

                -- Link herb ↔ constituent in junction table
                INSERT IGNORE INTO ency.herb_constituent (herb_id, constituent_id)
                SELECT herb_id, c.record_id
                FROM ency.ency_constituent_tb c
                WHERE c.name = token
                LIMIT 1;
            END IF;

            IF remainder = '' THEN LEAVE token_loop; END IF;
        END LOOP token_loop;

    END LOOP read_loop;

    CLOSE herb_cur;
END$$
DELIMITER ;

CALL ency_import_constituents();
DROP PROCEDURE IF EXISTS ency_import_constituents;

-- ---------------------------------------------------------------------------
-- 3. PAGES: forager.page_tb → ency.page_tb
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
SELECT 'ency_herb_tb'       AS target_table, COUNT(*) AS total_rows FROM ency.ency_herb_tb
UNION ALL
SELECT 'ency_constituent_tb',             COUNT(*) FROM ency.ency_constituent_tb
UNION ALL
SELECT 'herb_constituent (junction)',     COUNT(*) FROM ency.herb_constituent
UNION ALL
SELECT 'page_tb (ENCY)',                  COUNT(*) FROM ency.page_tb WHERE sitename = 'ENCY';
