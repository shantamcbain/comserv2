#!/bin/bash
# Script to verify Phase 1 schema changes
# Run this after applying the migration

DB_HOST="${DB_HOST:-192.168.1.198}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-ency}"
DB_USER="${DB_USER:-comserv}"
DB_PASS="${DB_PASSWORD:-comserv_pass}"

echo "Verifying Phase 1 Database Schema Changes..."
echo "=============================================="

# Check if tables exist
echo -e "\n1. Checking if new tables exist..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "
SELECT 
    TABLE_NAME,
    TABLE_ROWS
FROM information_schema.TABLES 
WHERE TABLE_SCHEMA = '$DB_NAME' 
AND TABLE_NAME IN ('site_roles', 'user_site_roles', 'plan_audit');
"

# Check if allowed_roles column was added to dailyplan
echo -e "\n2. Checking allowed_roles column in dailyplan table..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "
SELECT 
    COLUMN_NAME,
    DATA_TYPE,
    IS_NULLABLE
FROM information_schema.COLUMNS 
WHERE TABLE_SCHEMA = '$DB_NAME' 
AND TABLE_NAME = 'dailyplan' 
AND COLUMN_NAME = 'allowed_roles';
"

# Check if allowed_roles column was added to todo
echo -e "\n3. Checking allowed_roles column in todo table..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "
SELECT 
    COLUMN_NAME,
    DATA_TYPE,
    IS_NULLABLE
FROM information_schema.COLUMNS 
WHERE TABLE_SCHEMA = '$DB_NAME' 
AND TABLE_NAME = 'todo' 
AND COLUMN_NAME = 'allowed_roles';
"

# Check foreign keys
echo -e "\n4. Checking foreign key constraints..."
mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "
SELECT 
    CONSTRAINT_NAME,
    TABLE_NAME,
    REFERENCED_TABLE_NAME
FROM information_schema.KEY_COLUMN_USAGE 
WHERE TABLE_SCHEMA = '$DB_NAME' 
AND TABLE_NAME IN ('user_site_roles', 'plan_audit')
AND REFERENCED_TABLE_NAME IS NOT NULL;
"

echo -e "\nVerification complete!"
