-- Health Kitchen nutrition tracking. REVIEW BEFORE APPLYING.
-- Normally created on dev via Admin > Schema Compare from HealthKitchen::FoodNutrient / ::IntakeLog.
-- source/source_ref allow a later public food DB import (USDA FDC, Open Food Facts) to upsert.
CREATE TABLE IF NOT EXISTS hk_food_nutrient (
    id INT NOT NULL AUTO_INCREMENT,
    sitename VARCHAR(255) NULL,
    name VARCHAR(255) NOT NULL,
    brand VARCHAR(255) NULL,
    source VARCHAR(32) NOT NULL DEFAULT 'manual',
    source_ref VARCHAR(64) NULL,
    inventory_item_id INT NULL,
    serving_size DECIMAL(10,2) NOT NULL DEFAULT 100,
    serving_unit VARCHAR(32) NOT NULL DEFAULT 'g',
    calories DECIMAL(10,2) NULL,
    protein_g DECIMAL(10,2) NULL,
    carbs_g DECIMAL(10,2) NULL,
    fat_g DECIMAL(10,2) NULL,
    fiber_g DECIMAL(10,2) NULL,
    sugar_g DECIMAL(10,2) NULL,
    sodium_mg DECIMAL(10,2) NULL,
    extra_json TEXT NULL,
    created_by INT NULL,
    created_at DATETIME NULL,
    updated_at DATETIME NULL,
    PRIMARY KEY (id),
    UNIQUE KEY hk_food_nutrient_source (source, source_ref),
    KEY hk_food_nutrient_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hk_intake_log (
    id INT NOT NULL AUTO_INCREMENT,
    user_id INT NOT NULL,
    sitename VARCHAR(255) NOT NULL,
    log_date DATE NOT NULL,
    meal_slot VARCHAR(20) NULL,
    food_nutrient_id INT NULL,
    food_name VARCHAR(255) NOT NULL,
    servings DECIMAL(10,2) NOT NULL DEFAULT 1,
    calories DECIMAL(10,2) NULL,
    protein_g DECIMAL(10,2) NULL,
    carbs_g DECIMAL(10,2) NULL,
    fat_g DECIMAL(10,2) NULL,
    fiber_g DECIMAL(10,2) NULL,
    sugar_g DECIMAL(10,2) NULL,
    sodium_mg DECIMAL(10,2) NULL,
    notes TEXT NULL,
    created_at DATETIME NULL,
    updated_at DATETIME NULL,
    PRIMARY KEY (id),
    KEY hk_intake_user_day (user_id, sitename, log_date)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
