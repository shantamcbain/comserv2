-- HealthKitchen: review queue for user-submitted ENCY additions (symptoms first).
-- NOT APPLIED. Apply via Admin > Schema Compare or manually after approval.
CREATE TABLE IF NOT EXISTS hk_pending_ency_addition (
  id                INT NOT NULL AUTO_INCREMENT,
  user_id           INT NOT NULL,
  username          VARCHAR(255) NULL,
  sitename          VARCHAR(255) NOT NULL,
  entity_type       VARCHAR(20)  NOT NULL,              -- 'symptom'
  payload           TEXT NOT NULL,                       -- JSON {name, description, severity}
  status            VARCHAR(20)  NOT NULL DEFAULT 'pending', -- pending|approved|rejected
  reviewer_user_id  INT NULL,
  reviewer_username VARCHAR(255) NULL,
  review_notes      TEXT NULL,
  ency_record_id    INT NULL,
  todo_id           INT NULL,
  reviewed_at       DATETIME NULL,
  created_at        DATETIME NULL,
  updated_at        DATETIME NULL,
  PRIMARY KEY (id),
  KEY hk_pending_status (status, entity_type),
  KEY hk_pending_user (user_id, sitename)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
