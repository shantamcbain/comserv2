CREATE TABLE IF NOT EXISTS formula_constituent (
  id             INT(11)       NOT NULL AUTO_INCREMENT,
  formula_id     INT(11)       NOT NULL,
  constituent_id INT(11)       NOT NULL,
  quantity       DECIMAL(10,4) NULL,
  unit           VARCHAR(30)   NULL,
  plant_part     VARCHAR(100)  NULL,
  notes          TEXT          NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_formula_constituent (formula_id, constituent_id, plant_part),
  KEY idx_formula_id (formula_id),
  KEY idx_constituent_id (constituent_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
