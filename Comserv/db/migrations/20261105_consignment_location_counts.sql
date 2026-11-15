-- Migration: 20261105_consignment_location_counts.sql
-- Purpose: Photo-count workflow for consignment placements.
--          A placement attaches a storage location to a consignment partner and
--          one item, with the quantities we MAINTAIN there per colour.
--          A count records one physical count (photo -> verified text -> applied).
--          Colour stays an attribute (count line / print job), NOT a separate
--          inventory item: filament consumption is tracked per print job, so
--          colour SKUs would add BOM/stock/shop rows with no accuracy gain.
-- Author: AI Assistant (Director/Coder)
-- Date: 2026-11-05
-- Note: NO ALTERs to existing tables - new tables only, so the live app is
--       unaffected until the code paths use them.

-- ============================================================
-- Consignment placements (location <-> partner <-> item + maintained target)
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory_consignment_placements (
    id                    INT AUTO_INCREMENT PRIMARY KEY,
    sitename              VARCHAR(255) NOT NULL,
    location_id           INT NOT NULL,
    partner_id            INT NOT NULL,
    item_id               INT NOT NULL,
    invoice_customer_name VARCHAR(255)    DEFAULT NULL
        COMMENT 'Customer the sale is invoiced to (partner name may differ, e.g. MCoop)',
    commission_percent    DECIMAL(5,2)    DEFAULT NULL
        COMMENT 'Override of the partner commission for this placement; NULL = partner rate',
    target_counts         TEXT            DEFAULT NULL
        COMMENT 'JSON of maintained qty per colour, e.g. {"blue":2,"yellow":2,"red":2,"green":2}',
    colours               VARCHAR(255)    DEFAULT NULL
        COMMENT 'Display order of colours for the count screen, CSV',
    status                VARCHAR(50)  NOT NULL DEFAULT 'active',
    notes                 TEXT            DEFAULT NULL,
    created_by            VARCHAR(255)    DEFAULT NULL,
    created_at            DATETIME         DEFAULT CURRENT_TIMESTAMP,
    updated_at            DATETIME         DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_placement (location_id, partner_id, item_id),
    INDEX idx_placement_sitename (sitename),
    INDEX idx_placement_partner  (partner_id),
    INDEX idx_placement_status   (status),
    CONSTRAINT fk_placement_location FOREIGN KEY (location_id)
        REFERENCES inventory_locations (id) ON DELETE CASCADE,
    CONSTRAINT fk_placement_partner FOREIGN KEY (partner_id)
        REFERENCES inventory_consignment_partners (id) ON DELETE CASCADE,
    CONSTRAINT fk_placement_item FOREIGN KEY (item_id)
        REFERENCES inventory_items (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ============================================================
-- Location counts (one physical count of a placement's container)
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory_location_counts (
    id               INT AUTO_INCREMENT PRIMARY KEY,
    sitename         VARCHAR(255) NOT NULL,
    placement_id     INT              DEFAULT NULL,
    location_id      INT          NOT NULL,
    partner_id       INT              DEFAULT NULL,
    item_id          INT          NOT NULL,
    source           VARCHAR(50)  NOT NULL DEFAULT 'photo'
        COMMENT 'photo | manual | chat',
    image_path       VARCHAR(500)     DEFAULT NULL
        COMMENT 'Transient evidence file; deleted once the text is confirmed',
    image_mime       VARCHAR(100)     DEFAULT NULL,
    image_deleted_at DATETIME         DEFAULT NULL,
    raw_text         TEXT             DEFAULT NULL
        COMMENT 'The verified count text, e.g. "2 blue, 2 yellow, 1 red, 0 green"',
    engine           VARCHAR(100)     DEFAULT NULL
        COMMENT 'Vision model that produced raw_text',
    confidence       DECIMAL(5,2)     DEFAULT NULL,
    status           VARCHAR(50)  NOT NULL DEFAULT 'draft'
        COMMENT 'draft | applied | void',
    counted_by       VARCHAR(255)     DEFAULT NULL,
    counted_at       DATETIME         DEFAULT NULL,
    applied_at       DATETIME         DEFAULT NULL,
    consignment_id   INT              DEFAULT NULL COMMENT 'Consignment settled by this count',
    invoice_id       INT              DEFAULT NULL COMMENT 'Draft sales invoice raised by this count',
    traveller_id     INT              DEFAULT NULL COMMENT 'Top-up traveller raised by this count',
    notes            TEXT             DEFAULT NULL,
    created_at       DATETIME         DEFAULT CURRENT_TIMESTAMP,
    updated_at       DATETIME         DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_count_sitename  (sitename),
    INDEX idx_count_location  (location_id),
    INDEX idx_count_placement (placement_id),
    INDEX idx_count_status    (status),
    INDEX idx_count_counted   (counted_at),
    CONSTRAINT fk_count_placement FOREIGN KEY (placement_id)
        REFERENCES inventory_consignment_placements (id) ON DELETE SET NULL,
    CONSTRAINT fk_count_location FOREIGN KEY (location_id)
        REFERENCES inventory_locations (id) ON DELETE CASCADE,
    CONSTRAINT fk_count_item FOREIGN KEY (item_id)
        REFERENCES inventory_items (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ============================================================
-- Location count lines (one row per colour)
-- ============================================================
CREATE TABLE IF NOT EXISTS inventory_location_count_lines (
    id             INT AUTO_INCREMENT PRIMARY KEY,
    count_id       INT          NOT NULL,
    item_id        INT              DEFAULT NULL,
    colour         VARCHAR(50)  NOT NULL,
    qty_expected   DECIMAL(12,3) NOT NULL DEFAULT 0
        COMMENT 'Maintained target at this location',
    qty_counted    DECIMAL(12,3) NOT NULL DEFAULT 0
        COMMENT 'Physically counted (from the verified text)',
    qty_delta      DECIMAL(12,3) NOT NULL DEFAULT 0
        COMMENT 'counted - expected; negative = units left the location (sold)',
    filament_color VARCHAR(50)      DEFAULT NULL
        COMMENT 'Filament colour the top-up print job should use',
    sort_order     INT              DEFAULT 0,
    notes          TEXT             DEFAULT NULL,
    created_at     DATETIME         DEFAULT CURRENT_TIMESTAMP,
    updated_at     DATETIME         DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_count_colour (count_id, colour),
    INDEX idx_count_line_count (count_id),
    CONSTRAINT fk_count_line_count FOREIGN KEY (count_id)
        REFERENCES inventory_location_counts (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
