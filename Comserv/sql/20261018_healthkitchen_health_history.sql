-- Health Kitchen opt-in health & disease history. REVIEW BEFORE APPLYING.
-- Normally created on dev via Admin > Schema Compare from HealthKitchen::HealthConsent,
-- ::HealthHistory, ::HealthAudit. Do not run on production unreviewed.
-- Encrypted columns (Comserv::Util::Encryption, namespace 'healthkitchen', 'ENC:' prefix):
--   hk_health_consent.ip_address, hk_health_consent.user_agent,
--   hk_health_history.label, hk_health_history.notes
CREATE TABLE IF NOT EXISTS hk_health_consent (
    id INT NOT NULL AUTO_INCREMENT,
    user_id INT NOT NULL,
    sitename VARCHAR(255) NOT NULL,
    consent_version VARCHAR(20) NOT NULL DEFAULT '1',
    granted_at DATETIME NOT NULL,
    revoked_at DATETIME NULL,
    ip_address TEXT NULL,
    user_agent TEXT NULL,
    created_at DATETIME NULL,
    updated_at DATETIME NULL,
    PRIMARY KEY (id),
    KEY hk_health_consent_user (user_id, sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hk_health_history (
    id INT NOT NULL AUTO_INCREMENT,
    user_id INT NOT NULL,
    sitename VARCHAR(255) NOT NULL,
    entry_type VARCHAR(20) NOT NULL DEFAULT 'condition',
    ency_disease_id INT NULL,
    ency_symptom_id INT NULL,
    ency_drug_id INT NULL,
    label TEXT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    onset_date DATE NULL,
    resolved_date DATE NULL,
    severity VARCHAR(20) NULL,
    notes TEXT NULL,
    use_for_matching TINYINT NOT NULL DEFAULT 1,
    visibility VARCHAR(20) NOT NULL DEFAULT 'private',
    created_at DATETIME NULL,
    updated_at DATETIME NULL,
    PRIMARY KEY (id),
    KEY hk_health_history_user (user_id, sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hk_health_audit (
    id INT NOT NULL AUTO_INCREMENT,
    actor_user_id INT NOT NULL,
    subject_user_id INT NOT NULL,
    sitename VARCHAR(255) NOT NULL,
    action VARCHAR(40) NOT NULL,
    entry_count INT NULL,
    created_at DATETIME NULL,
    updated_at DATETIME NULL,
    PRIMARY KEY (id),
    KEY hk_health_audit_subject (subject_user_id, sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
