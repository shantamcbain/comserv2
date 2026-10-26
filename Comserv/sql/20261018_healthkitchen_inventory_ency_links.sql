-- HealthKitchen: multi-entity ENCY links + product details for pantry/inventory items.
-- NOT APPLIED. Apply via Admin > Schema Compare (preferred) or manually after approval.
-- Animal entities use the existing ency_animal_tb; constituents use ency_constituent_tb.

CREATE TABLE IF NOT EXISTS hk_inventory_ency_link (
  id               INT NOT NULL AUTO_INCREMENT,
  sitename         VARCHAR(255) NOT NULL,
  item_kind        VARCHAR(20)  NOT NULL,   -- 'inventory' | 'pantry'
  item_id          INT NOT NULL,
  entity_type      VARCHAR(20)  NOT NULL,   -- 'herb' | 'animal' | 'constituent'
  entity_id        INT NOT NULL,
  added_by_user_id INT NULL,
  notes            TEXT NULL,
  created_at       DATETIME NULL,
  updated_at       DATETIME NULL,
  PRIMARY KEY (id),
  UNIQUE KEY hk_link_unique (sitename, item_kind, item_id, entity_type, entity_id),
  KEY hk_link_entity (entity_type, entity_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS hk_item_product (
  id         INT NOT NULL AUTO_INCREMENT,
  sitename   VARCHAR(255) NOT NULL,
  item_kind  VARCHAR(20)  NOT NULL,
  item_id    INT NOT NULL,
  brand      VARCHAR(255) NULL,
  upc        VARCHAR(32)  NULL,
  size_value DECIMAL(12,3) NULL,
  size_unit  VARCHAR(20)  NULL,
  created_at DATETIME NULL,
  updated_at DATETIME NULL,
  PRIMARY KEY (id),
  UNIQUE KEY hk_product_item (sitename, item_kind, item_id),
  KEY hk_product_upc (upc)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Optional back-fill of existing single-row maps (run once after creating the table):
-- INSERT IGNORE INTO hk_inventory_ency_link (sitename,item_kind,item_id,entity_type,entity_id,created_at,updated_at)
--   SELECT sitename,'inventory',inventory_item_id,'herb',herb_id,NOW(),NOW() FROM hk_inventory_ency_map WHERE herb_id IS NOT NULL;
-- INSERT IGNORE INTO hk_inventory_ency_link (sitename,item_kind,item_id,entity_type,entity_id,created_at,updated_at)
--   SELECT sitename,'inventory',inventory_item_id,'animal',animal_id,NOW(),NOW() FROM hk_inventory_ency_map WHERE animal_id IS NOT NULL;
