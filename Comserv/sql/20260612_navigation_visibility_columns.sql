-- Navigation visibility: guest vs member filtering for menu links and hosted catalogue.
-- Runtime ALTER also exists in Navigation.pm (_ensure_*_column); this script is for manual/schema-compare use.

SET @schema_name = DATABASE();

-- internal_links_tb.public_visible
SELECT COUNT(*)
INTO @has_public_visible
FROM information_schema.columns
WHERE table_schema = @schema_name
  AND table_name = 'internal_links_tb'
  AND column_name = 'public_visible';

SET @add_public_visible = IF(
    @has_public_visible = 0,
    'ALTER TABLE internal_links_tb ADD COLUMN public_visible tinyint(1) NOT NULL DEFAULT 1 AFTER status',
    'SELECT "internal_links_tb.public_visible already present"'
);
PREPARE stmt FROM @add_public_visible;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- hosting_accounts.list_publicly
SELECT COUNT(*)
INTO @has_list_publicly
FROM information_schema.columns
WHERE table_schema = @schema_name
  AND table_name = 'hosting_accounts'
  AND column_name = 'list_publicly';

SET @add_list_publicly = IF(
    @has_list_publicly = 0,
    'ALTER TABLE hosting_accounts ADD COLUMN list_publicly tinyint(1) NOT NULL DEFAULT 1 AFTER status',
    'SELECT "hosting_accounts.list_publicly already present"'
);
PREPARE stmt FROM @add_list_publicly;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;