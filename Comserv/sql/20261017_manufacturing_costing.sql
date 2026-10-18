-- Manufacturing costing, phase 1 (branch 3d). Minimal: 4 columns + 1 table.
-- Safe to run once; the code skips these pieces (with a warning) until they exist.
ALTER TABLE inventory_items
  ADD COLUMN markup_percent DECIMAL(6,2) NULL COMMENT 'NULL = <Manufacturing> markup_percent default',
  ADD COLUMN manual_price  TINYINT(1)   NOT NULL DEFAULT 0 COMMENT '1 = never auto-update selling_price';
ALTER TABLE printing_3d_jobs
  ADD COLUMN labour_cost    DECIMAL(10,4) NULL,
  ADD COLUMN cost_breakdown TEXT          NULL COMMENT 'JSON: per-step minutes, components, scrap, unit cost';
CREATE TABLE IF NOT EXISTS mfg_cost_history (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  sitename    VARCHAR(100) NULL,
  item_id     INT          NOT NULL,
  job_id      INT          NULL,
  event       VARCHAR(30)  NOT NULL COMMENT 'job_complete | labour_log | manual',
  old_cost    DECIMAL(12,4) NULL,
  new_cost    DECIMAL(12,4) NULL,
  old_price   DECIMAL(12,2) NULL,
  new_price   DECIMAL(12,2) NULL,
  detail      TEXT          NULL COMMENT 'JSON breakdown',
  created_by  VARCHAR(100)  NULL,
  created_at  DATETIME      NOT NULL,
  KEY idx_item (item_id, created_at),
  KEY idx_job (job_id)
);
-- Undo:
-- ALTER TABLE inventory_items DROP COLUMN markup_percent, DROP COLUMN manual_price;
-- ALTER TABLE printing_3d_jobs DROP COLUMN labour_cost, DROP COLUMN cost_breakdown;
-- DROP TABLE mfg_cost_history;
