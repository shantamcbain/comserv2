-- HealthPlanning Feature — Database Schema Migration
-- Developer: CSC  |  Revenue Site: Shanta SiteName
-- Project Code: HLTHPLAN-SHANTA
--
-- Run against the ENCY database.
-- All tables use IF NOT EXISTS so the script is safe to re-run.

-- ---------------------------------------------------------------------------
-- 1. Symptoms catalog
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_symptoms (
    id          INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    description TEXT,
    category    VARCHAR(100),
    sitename    VARCHAR(255),
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_hs_name     (name),
    INDEX idx_hs_sitename (sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 2. Diseases / conditions catalog
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_diseases (
    id               INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name             VARCHAR(255) NOT NULL,
    description      TEXT,
    icd_code         VARCHAR(20),
    natural_approach TEXT,
    allopathic_notes TEXT,
    sitename         VARCHAR(255),
    created_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_hd_name     (name),
    INDEX idx_hd_sitename (sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 3. Symptom ↔ Disease weighted mapping
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_symptom_disease_map (
    id         INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    symptom_id INT NOT NULL,
    disease_id INT NOT NULL,
    weight     DECIMAL(5,2) DEFAULT 1.00,
    INDEX idx_hsdm_symptom (symptom_id),
    INDEX idx_hsdm_disease (disease_id),
    CONSTRAINT fk_hsdm_symptom FOREIGN KEY (symptom_id) REFERENCES health_symptoms(id)  ON DELETE CASCADE,
    CONSTRAINT fk_hsdm_disease FOREIGN KEY (disease_id) REFERENCES health_diseases(id)  ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 4. Practitioner type catalog
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_practitioner_types (
    id          INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    description TEXT,
    sitename    VARCHAR(255),
    INDEX idx_hpt_sitename (sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 5. Disease ↔ Recommended practitioner mapping
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_disease_practitioners (
    id                   INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    disease_id           INT NOT NULL,
    practitioner_type_id INT NOT NULL,
    priority             INT DEFAULT 1,
    INDEX idx_hdp_disease (disease_id),
    CONSTRAINT fk_hdp_disease      FOREIGN KEY (disease_id)           REFERENCES health_diseases(id)           ON DELETE CASCADE,
    CONSTRAINT fk_hdp_practitioner FOREIGN KEY (practitioner_type_id) REFERENCES health_practitioner_types(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 6. Member health plan (top-level)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_member_plans (
    id         INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id    INT NOT NULL,
    sitename   VARCHAR(255) NOT NULL,
    goal       TEXT,
    status     VARCHAR(50) DEFAULT 'active',
    start_date DATE,
    end_date   DATE,
    disease_id INT,
    notes      TEXT,
    created_by VARCHAR(100),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_hmp_user     (user_id),
    INDEX idx_hmp_sitename (sitename),
    INDEX idx_hmp_status   (status),
    CONSTRAINT fk_hmp_disease FOREIGN KEY (disease_id) REFERENCES health_diseases(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 7. Diet plan (linked to member plan)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_diet_plans (
    id                 INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    plan_id            INT NOT NULL,
    dietary_protocol   VARCHAR(255),
    description        TEXT,
    foods_to_emphasise TEXT,
    foods_to_avoid     TEXT,
    created_at         DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_hdp2_plan (plan_id),
    CONSTRAINT fk_hdp2_plan FOREIGN KEY (plan_id) REFERENCES health_member_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 8. Meal plan (linked to diet plan)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_meal_plans (
    id              INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    diet_plan_id    INT NOT NULL,
    meal_slot       VARCHAR(50),
    day_of_week     VARCHAR(20) DEFAULT 'any',
    recipe_name     VARCHAR(255),
    ingredients     TEXT,
    instructions    TEXT,
    inventory_check TINYINT(1) DEFAULT 0,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_hmpl_diet (diet_plan_id),
    CONSTRAINT fk_hmpl_diet FOREIGN KEY (diet_plan_id) REFERENCES health_diet_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 9. Herb prescriptions (linked to member plan, references ency_herb_tb)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_herb_prescriptions (
    id             INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    plan_id        INT NOT NULL,
    herb_record_id INT,
    herb_name      VARCHAR(255),
    dosage         VARCHAR(255),
    preparation    VARCHAR(255),
    frequency      VARCHAR(100),
    duration_weeks INT,
    priority       INT DEFAULT 1,
    notes          TEXT,
    created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_hhp_plan (plan_id),
    INDEX idx_hhp_herb (herb_record_id),
    CONSTRAINT fk_hhp_plan FOREIGN KEY (plan_id) REFERENCES health_member_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 10. Exercise plans (linked to member plan)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_exercise_plans (
    id                 INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    plan_id            INT NOT NULL,
    exercise_type      VARCHAR(100),
    frequency_per_week INT,
    duration_minutes   INT,
    intensity          VARCHAR(50),
    description        TEXT,
    created_at         DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_hep_plan (plan_id),
    CONSTRAINT fk_hep_plan FOREIGN KEY (plan_id) REFERENCES health_member_plans(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- 11. Health inventory items (food, herbs, supplements per site)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS health_inventory_items (
    id                  INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sitename            VARCHAR(255) NOT NULL,
    item_name           VARCHAR(255) NOT NULL,
    item_type           VARCHAR(50),
    herb_record_id      INT,
    quantity            DECIMAL(10,2) DEFAULT 0.00,
    unit                VARCHAR(50),
    low_stock_threshold DECIMAL(10,2) DEFAULT 0.00,
    reorder_quantity    DECIMAL(10,2) DEFAULT 0.00,
    notes               TEXT,
    updated_at          DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_hii_sitename (sitename),
    INDEX idx_hii_type     (item_type)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
