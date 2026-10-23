-- Health Kitchen meal plans (inventory-first). REVIEW BEFORE APPLYING.
-- Normally created on dev via Admin > Schema Compare from the DBIC result classes
-- HealthKitchen::MealPlan / HealthKitchen::MealPlanEntry. Do not run on production unreviewed.
CREATE TABLE IF NOT EXISTS hk_meal_plan (
    id          INT NOT NULL AUTO_INCREMENT,
    user_id     INT NOT NULL,
    sitename    VARCHAR(255) NOT NULL,
    name        VARCHAR(255) NOT NULL,
    start_date  DATE NULL,
    end_date    DATE NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'draft',
    notes       TEXT NULL,
    created_at  DATETIME NULL,
    updated_at  DATETIME NULL,
    PRIMARY KEY (id),
    KEY hk_meal_plan_user_site (user_id, sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hk_meal_plan_entry (
    id            INT NOT NULL AUTO_INCREMENT,
    meal_plan_id  INT NOT NULL,
    plan_date     DATE NULL,
    meal_slot     VARCHAR(20) NOT NULL DEFAULT 'dinner',
    recipe_id     INT NULL,
    custom_name   VARCHAR(255) NULL,
    servings      DECIMAL(10,2) NOT NULL DEFAULT 1,
    notes         TEXT NULL,
    created_at    DATETIME NULL,
    updated_at    DATETIME NULL,
    PRIMARY KEY (id),
    KEY hk_meal_plan_entry_plan (meal_plan_id),
    KEY hk_meal_plan_entry_recipe (recipe_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
