-- Allow each site to define its own page_code, such as "home".
-- pages_content.page_code was previously globally unique.

SET @schema_name = DATABASE();

SELECT COUNT(*)
INTO @has_unique_page_code
FROM information_schema.statistics
WHERE table_schema = @schema_name
  AND table_name = 'pages_content'
  AND index_name = 'unique_page_code';

SET @drop_unique_page_code = IF(
    @has_unique_page_code > 0,
    'ALTER TABLE pages_content DROP INDEX unique_page_code',
    'SELECT "unique_page_code index not present"'
);
PREPARE stmt FROM @drop_unique_page_code;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SELECT COUNT(*)
INTO @has_page_code
FROM information_schema.statistics
WHERE table_schema = @schema_name
  AND table_name = 'pages_content'
  AND index_name = 'page_code';

SET @drop_page_code = IF(
    @has_page_code > 0,
    'ALTER TABLE pages_content DROP INDEX page_code',
    'SELECT "page_code index not present"'
);
PREPARE stmt FROM @drop_page_code;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SELECT COUNT(*)
INTO @has_unique_sitename_page_code
FROM information_schema.statistics
WHERE table_schema = @schema_name
  AND table_name = 'pages_content'
  AND index_name = 'unique_sitename_page_code';

SET @add_unique_sitename_page_code = IF(
    @has_unique_sitename_page_code = 0,
    'ALTER TABLE pages_content ADD UNIQUE KEY unique_sitename_page_code (sitename, page_code)',
    'SELECT "unique_sitename_page_code index already present"'
);
PREPARE stmt FROM @add_unique_sitename_page_code;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
