-- PointSystem Project Migration
-- Adds the PointSystem as a new top-level project in the planning database
-- and creates all required sub-projects for the internal payment system.
--
-- Run this against your production/development database to register the project.
-- The PointSystem is an internal payment system allowing members to earn and
-- spend points, equivalent to Canadian Dollars, with multi-currency support.

-- Insert the parent PointSystem project (top-level)
INSERT INTO `projects` (
    `name`,
    `description`,
    `start_date`,
    `end_date`,
    `status`,
    `record_id`,
    `project_code`,
    `project_size`,
    `estimated_man_hours`,
    `developer_name`,
    `client_name`,
    `sitename`,
    `comments`,
    `username_of_poster`,
    `group_of_poster`,
    `date_time_posted`,
    `parent_id`
) VALUES (
    'Point System',
    'Internal payment system allowing members to earn and spend points within the application. '
    'Points are the primary currency within the system. One point equals one Canadian Dollar. '
    'The system handles multiple currencies via exchange rates, PayPal transactions and subscriptions, '
    'and is designed for future crypto-coin integration (e.g. Steem-style blockchain coin).',
    '2025-03-25',
    '2027-01-01',
    'In-Process',
    0,
    'PointSystem',
    8,
    200,
    'Shanta',
    'CSC',
    'CSC',
    'Separated from Members branch - too large to be a Members sub-task. '
    'Members receive 100-point joining bonus. Supports PayPal one-time and subscription payments. '
    'Future: accept crypto currencies and potentially convert points to a real crypto coin.',
    'Shanta',
    'admin',
    NOW(),
    NULL
);

-- Capture the new parent project ID
SET @point_system_id = LAST_INSERT_ID();

-- Sub-project: Point Account & Ledger
INSERT INTO `projects` (
    `name`, `description`, `start_date`, `end_date`, `status`,
    `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
    `developer_name`, `client_name`, `sitename`, `comments`,
    `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`
) VALUES (
    'Point Accounts and Ledger',
    'Member point balance tracking, transaction ledger, and joining bonus (100-point credit on registration).',
    '2025-03-25', '2026-01-01', 'In-Process',
    0, 'PointLedger', 3, 40,
    'Shanta', 'CSC', 'CSC',
    'Core point balance and history system. New members receive 100 points. '
    'Full audit trail of all point movements.',
    'Shanta', 'admin', NOW(), @point_system_id
);

-- Sub-project: Currency Exchange
INSERT INTO `projects` (
    `name`, `description`, `start_date`, `end_date`, `status`,
    `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
    `developer_name`, `client_name`, `sitename`, `comments`,
    `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`
) VALUES (
    'Currency Exchange and Multi-Currency Support',
    'Exchange rate management so points can be displayed in any currency. '
    'Base currency is Canadian Dollar (1 point = 1 CAD). Rates updated periodically via external API.',
    '2025-03-25', '2026-06-01', 'Requested',
    0, 'PointCurrency', 3, 30,
    'Shanta', 'CSC', 'CSC',
    'Allows site operators to display prices in their currency of choice. '
    'Exchange rates stored in DB and refreshed on schedule.',
    'Shanta', 'admin', NOW(), @point_system_id
);

-- Sub-project: PayPal Integration
INSERT INTO `projects` (
    `name`, `description`, `start_date`, `end_date`, `status`,
    `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
    `developer_name`, `client_name`, `sitename`, `comments`,
    `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`
) VALUES (
    'PayPal Payment Integration',
    'Allow members to purchase points via PayPal. Supports one-time transactions and recurring subscriptions. '
    'Handles IPN/webhook callbacks, payment verification, and automatic point crediting.',
    '2025-03-25', '2026-06-01', 'Requested',
    0, 'PointPayPal', 4, 60,
    'Shanta', 'CSC', 'CSC',
    'PayPal REST API integration for buying points. '
    'One-time purchases and monthly/annual subscription plans. '
    'IPN callbacks to credit points on successful payment.',
    'Shanta', 'admin', NOW(), @point_system_id
);

-- Sub-project: Point Spending and Service Payments
INSERT INTO `projects` (
    `name`, `description`, `start_date`, `end_date`, `status`,
    `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
    `developer_name`, `client_name`, `sitename`, `comments`,
    `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`
) VALUES (
    'Point Spending and Service Payments',
    'Allow members to spend points to pay for services offered by other members within the system. '
    'Integrates with service listings, invoicing, and checkout flows.',
    '2025-03-25', '2026-09-01', 'Requested',
    0, 'PointSpend', 3, 40,
    'Shanta', 'CSC', 'CSC',
    'Point-based checkout for member services. '
    'Debit/credit between member accounts. Refund handling.',
    'Shanta', 'admin', NOW(), @point_system_id
);

-- Sub-project: Crypto Coin Integration (Future)
INSERT INTO `projects` (
    `name`, `description`, `start_date`, `end_date`, `status`,
    `record_id`, `project_code`, `project_size`, `estimated_man_hours`,
    `developer_name`, `client_name`, `sitename`, `comments`,
    `username_of_poster`, `group_of_poster`, `date_time_posted`, `parent_id`
) VALUES (
    'Crypto Coin Integration',
    'Future phase: accept cryptocurrency payments and explore converting the point system into a real '
    'blockchain-based crypto coin (similar to Steem/Hive). Integration with existing crypto networks.',
    '2026-01-01', '2028-01-01', 'Requested',
    0, 'PointCrypto', 5, 150,
    'Shanta', 'CSC', 'CSC',
    'Phase 2 of the point system. Research Steem/Hive integration. '
    'Evaluate creating a custom coin on an existing blockchain platform. '
    'Accept BTC, ETH, and other major coins as payment for points.',
    'Shanta', 'admin', NOW(), @point_system_id
);
