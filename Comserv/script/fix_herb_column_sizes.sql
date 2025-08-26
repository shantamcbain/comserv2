-- Fix column sizes for ency_herb_tb table to accommodate longer text
-- This addresses the "Data too long for column" errors

USE comserv;

-- Increase distribution column size from 100 to 500 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN distribution VARCHAR(500) NOT NULL DEFAULT '';

-- Increase flowers column size from 150 to 500 characters  
ALTER TABLE ency_herb_tb MODIFY COLUMN flowers VARCHAR(500) NOT NULL DEFAULT '';

-- Increase contra_indications column size from 150 to 500 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN contra_indications VARCHAR(500) NOT NULL DEFAULT '';

-- Increase preparation column size from 150 to 500 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN preparation VARCHAR(500) NOT NULL DEFAULT '';

-- Increase odour column size from 100 to 250 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN odour VARCHAR(250) NOT NULL DEFAULT '';

-- Increase solvents column size from 100 to 250 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN solvents VARCHAR(250) NOT NULL DEFAULT '';

-- Increase sister_plants column size from 100 to 250 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN sister_plants VARCHAR(250) NOT NULL DEFAULT '';

-- Increase pollinator column size from 100 to 250 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN pollinator VARCHAR(250) NOT NULL DEFAULT '';

-- Increase apis column size from 100 to 250 characters
ALTER TABLE ency_herb_tb MODIFY COLUMN apis VARCHAR(250) NOT NULL DEFAULT '';

-- Show the updated column definitions
DESCRIBE ency_herb_tb;