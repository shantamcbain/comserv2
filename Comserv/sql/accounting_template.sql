-- ============================================================================
-- Comserv Accounting Template Database
-- Modelled on SQL-Ledger / LedgerSMB double-entry accounting schema
-- PostgreSQL 14+
--
-- Usage:
--   createdb accounting_template
--   psql accounting_template < accounting_template.sql
--
-- To provision a new SiteName:
--   CREATE DATABASE sitename_accounting TEMPLATE accounting_template;
-- ============================================================================

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

-- ----------------------------------------------------------------------------
-- defaults — site configuration (one row per key)
-- Seeded at provisioning time with jurisdiction-specific values
-- ----------------------------------------------------------------------------
CREATE TABLE defaults (
    setting_key  varchar(50)  PRIMARY KEY,
    value        text
);

-- ----------------------------------------------------------------------------
-- employee — internal users who can post transactions
-- ----------------------------------------------------------------------------
CREATE TABLE employee (
    id           serial       PRIMARY KEY,
    login        varchar(30)  UNIQUE,
    name         varchar(255) NOT NULL,
    address1     varchar(255),
    address2     varchar(255),
    city         varchar(100),
    state        varchar(100),
    zipcode      varchar(20),
    country      varchar(100),
    workphone    varchar(50),
    homephone    varchar(50),
    startdate    date,
    enddate      date,
    notes        text,
    role         varchar(30)  DEFAULT 'user',
    sales        boolean      DEFAULT false,
    email        varchar(255),
    ssn          varchar(50),
    iban         varchar(100),
    bic          varchar(20),
    manager_id   integer      REFERENCES employee(id) ON DELETE SET NULL,
    created_at   timestamptz  DEFAULT now(),
    updated_at   timestamptz  DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- department — profit/cost centres
-- ----------------------------------------------------------------------------
CREATE TABLE department (
    id           serial       PRIMARY KEY,
    description  varchar(255) NOT NULL,
    role         char(1)      DEFAULT 'P' CHECK (role IN ('C','P'))
);

-- ----------------------------------------------------------------------------
-- chart — Chart of Accounts
-- charttype: A = account, H = heading
-- category:  A=Asset  L=Liability  Q=Equity  I=Income  E=Expense
-- link: colon-separated flags e.g. 'AP:AP_paid:IC_cogs'
-- ----------------------------------------------------------------------------
CREATE TABLE chart (
    id           serial       PRIMARY KEY,
    accno        varchar(30)  NOT NULL UNIQUE,
    description  text         NOT NULL,
    charttype    char(1)      NOT NULL DEFAULT 'A' CHECK (charttype IN ('A','H')),
    category     char(1)      NOT NULL CHECK (category IN ('A','L','Q','I','E')),
    link         text         DEFAULT '',
    gifi_accno   varchar(30),
    contra       boolean      DEFAULT false,
    tax          boolean      DEFAULT false,
    obsolete     boolean      DEFAULT false,
    heading      integer      REFERENCES chart(id) ON DELETE SET NULL,
    recon        boolean      DEFAULT false,
    notes        text,
    created_at   timestamptz  DEFAULT now()
);
CREATE INDEX chart_accno_idx ON chart(accno);
CREATE INDEX chart_category_idx ON chart(category);

-- ----------------------------------------------------------------------------
-- taxmodule — pluggable tax calculation modules
-- ----------------------------------------------------------------------------
CREATE TABLE taxmodule (
    taxmodule_id  serial      PRIMARY KEY,
    taxmodulename varchar(50) NOT NULL UNIQUE
);

-- ----------------------------------------------------------------------------
-- tax — tax rates linked to chart accounts
-- ----------------------------------------------------------------------------
CREATE TABLE tax (
    chart_id      integer     NOT NULL REFERENCES chart(id) ON DELETE CASCADE,
    rate          numeric(10,7) NOT NULL DEFAULT 0,
    minvalue      numeric(15,5) DEFAULT 0,
    maxvalue      numeric(15,5) DEFAULT 0,
    taxnumber     varchar(255),
    pass          integer     DEFAULT 0,
    taxmodule_id  integer     REFERENCES taxmodule(taxmodule_id),
    PRIMARY KEY (chart_id)
);

-- ----------------------------------------------------------------------------
-- exchangerate — currency rates
-- ----------------------------------------------------------------------------
CREATE TABLE exchangerate (
    curr         char(3)      NOT NULL,
    transdate    date         NOT NULL,
    buy          numeric(10,5),
    sell         numeric(10,5),
    PRIMARY KEY (curr, transdate)
);

-- ----------------------------------------------------------------------------
-- payment — payment terms definitions
-- ----------------------------------------------------------------------------
CREATE TABLE payment (
    id           serial       PRIMARY KEY,
    description  varchar(255) NOT NULL,
    terms        integer      DEFAULT 0,
    discount     numeric(5,2) DEFAULT 0,
    net          integer      DEFAULT 0
);

-- ----------------------------------------------------------------------------
-- pricegroup — customer price groups
-- ----------------------------------------------------------------------------
CREATE TABLE pricegroup (
    id           serial       PRIMARY KEY,
    pricegroup   varchar(100) NOT NULL
);

-- ----------------------------------------------------------------------------
-- partsgroup — item/product categories
-- ----------------------------------------------------------------------------
CREATE TABLE partsgroup (
    id           serial       PRIMARY KEY,
    partsgroup   varchar(100) NOT NULL
);

-- ----------------------------------------------------------------------------
-- parts — inventory items / SKUs
-- Mirrors InventoryItem from the main MySQL DB for accounting linkage
-- ----------------------------------------------------------------------------
CREATE TABLE parts (
    id                  serial        PRIMARY KEY,
    partnumber          varchar(255)  NOT NULL,
    description         text,
    unit                varchar(35),
    listprice           numeric(15,5) DEFAULT 0,
    sellprice           numeric(15,5) DEFAULT 0,
    lastcost            numeric(15,5) DEFAULT 0,
    priceupdate         date,
    weight              numeric(10,3) DEFAULT 0,
    onhand              numeric(15,5) DEFAULT 0,
    notes               text,
    makemodel           boolean       DEFAULT false,
    assembly            boolean       DEFAULT false,
    alternate           boolean       DEFAULT false,
    rop                 numeric(15,5) DEFAULT 0,
    inventory_accno_id  integer       REFERENCES chart(id) ON DELETE SET NULL,
    income_accno_id     integer       REFERENCES chart(id) ON DELETE SET NULL,
    expense_accno_id    integer       REFERENCES chart(id) ON DELETE SET NULL,
    returns_accno_id    integer       REFERENCES chart(id) ON DELETE SET NULL,
    bin                 varchar(255),
    obsolete            boolean       DEFAULT false,
    bom                 boolean       DEFAULT false,
    image               text,
    drawing             text,
    barcode             varchar(100),
    partsgroup_id       integer       REFERENCES partsgroup(id) ON DELETE SET NULL,
    project_id          integer,
    avgcost             numeric(15,5) DEFAULT 0,
    created_at          timestamptz   DEFAULT now(),
    updated_at          timestamptz   DEFAULT now()
);
CREATE INDEX parts_partnumber_idx ON parts(partnumber);
CREATE INDEX parts_obsolete_idx   ON parts(obsolete);

-- ----------------------------------------------------------------------------
-- makemodel — make/model lookup for parts
-- ----------------------------------------------------------------------------
CREATE TABLE makemodel (
    parts_id     integer      NOT NULL REFERENCES parts(id) ON DELETE CASCADE,
    make         varchar(255),
    model        varchar(255)
);
CREATE INDEX makemodel_parts_idx ON makemodel(parts_id);

-- ----------------------------------------------------------------------------
-- vendor — suppliers / creditors
-- ----------------------------------------------------------------------------
CREATE TABLE vendor (
    id                  serial        PRIMARY KEY,
    vendornumber        varchar(255),
    name                varchar(255)  NOT NULL,
    address1            varchar(255),
    address2            varchar(255),
    city                varchar(100),
    state               varchar(100),
    zipcode             varchar(20),
    country             varchar(100),
    contact             varchar(255),
    phone               varchar(50),
    fax                 varchar(50),
    email               text,
    cc                  text,
    bcc                 text,
    website             text,
    notes               text,
    terms               integer       DEFAULT 0,
    taxincluded         boolean       DEFAULT false,
    curr                char(3),
    employee_id         integer       REFERENCES employee(id) ON DELETE SET NULL,
    discount            numeric(5,2)  DEFAULT 0,
    creditlimit         numeric(15,5) DEFAULT 0,
    iban                varchar(100),
    bic                 varchar(20),
    language_code       varchar(6),
    payment_id          integer       REFERENCES payment(id) ON DELETE SET NULL,
    pricegroup_id       integer       REFERENCES pricegroup(id) ON DELETE SET NULL,
    startdate           date,
    enddate             date,
    arap_accno_id       integer       REFERENCES chart(id) ON DELETE SET NULL,
    payment_accno_id    integer       REFERENCES chart(id) ON DELETE SET NULL,
    discount_accno_id   integer       REFERENCES chart(id) ON DELETE SET NULL,
    cashdiscount        numeric(5,2)  DEFAULT 0,
    discountterms       integer       DEFAULT 0,
    taxnumber           varchar(100),
    gifi_accno          varchar(30),
    created_at          timestamptz   DEFAULT now(),
    updated_at          timestamptz   DEFAULT now()
);
CREATE INDEX vendor_name_idx ON vendor(name);

-- ----------------------------------------------------------------------------
-- customer — debtors / clients
-- ----------------------------------------------------------------------------
CREATE TABLE customer (
    id                  serial        PRIMARY KEY,
    customernumber      varchar(255),
    name                varchar(255)  NOT NULL,
    address1            varchar(255),
    address2            varchar(255),
    city                varchar(100),
    state               varchar(100),
    zipcode             varchar(20),
    country             varchar(100),
    contact             varchar(255),
    phone               varchar(50),
    fax                 varchar(50),
    email               text,
    cc                  text,
    bcc                 text,
    website             text,
    notes               text,
    terms               integer       DEFAULT 0,
    taxincluded         boolean       DEFAULT false,
    curr                char(3),
    employee_id         integer       REFERENCES employee(id) ON DELETE SET NULL,
    discount            numeric(5,2)  DEFAULT 0,
    creditlimit         numeric(15,5) DEFAULT 0,
    iban                varchar(100),
    bic                 varchar(20),
    language_code       varchar(6),
    payment_id          integer       REFERENCES payment(id) ON DELETE SET NULL,
    pricegroup_id       integer       REFERENCES pricegroup(id) ON DELETE SET NULL,
    startdate           date,
    enddate             date,
    arap_accno_id       integer       REFERENCES chart(id) ON DELETE SET NULL,
    payment_accno_id    integer       REFERENCES chart(id) ON DELETE SET NULL,
    discount_accno_id   integer       REFERENCES chart(id) ON DELETE SET NULL,
    cashdiscount        numeric(5,2)  DEFAULT 0,
    discountterms       integer       DEFAULT 0,
    taxnumber           varchar(100),
    gifi_accno          varchar(30),
    created_at          timestamptz   DEFAULT now(),
    updated_at          timestamptz   DEFAULT now()
);
CREATE INDEX customer_name_idx ON customer(name);

-- ----------------------------------------------------------------------------
-- shipto — shipping addresses for vendors/customers
-- ----------------------------------------------------------------------------
CREATE TABLE shipto (
    id           serial       PRIMARY KEY,
    trans_id     integer,
    transtype    varchar(10),
    shiptoname   varchar(255),
    address1     varchar(255),
    address2     varchar(255),
    city         varchar(100),
    state        varchar(100),
    zipcode      varchar(20),
    country      varchar(100),
    contact      varchar(255),
    phone        varchar(50),
    fax          varchar(50),
    email        text
);
CREATE INDEX shipto_trans_idx ON shipto(trans_id, transtype);

-- ----------------------------------------------------------------------------
-- gl — General Ledger journal entry headers
-- ----------------------------------------------------------------------------
CREATE TABLE gl (
    id            serial       PRIMARY KEY,
    reference     varchar(255),
    description   text,
    notes         text,
    transdate     date         NOT NULL DEFAULT current_date,
    department_id integer      REFERENCES department(id) ON DELETE SET NULL,
    employee_id   integer      REFERENCES employee(id) ON DELETE SET NULL,
    approved      boolean      DEFAULT true,
    cleared       boolean      DEFAULT false,
    created_at    timestamptz  DEFAULT now(),
    updated_at    timestamptz  DEFAULT now()
);
CREATE INDEX gl_transdate_idx ON gl(transdate);
CREATE INDEX gl_reference_idx ON gl(reference);

-- ----------------------------------------------------------------------------
-- ap — Accounts Payable (supplier invoices)
-- ----------------------------------------------------------------------------
CREATE TABLE ap (
    id               serial        PRIMARY KEY,
    invnumber        varchar(255),
    transdate        date          NOT NULL DEFAULT current_date,
    duedate          date,
    datepaid         date,
    amount           numeric(15,5) DEFAULT 0,
    netamount        numeric(15,5) DEFAULT 0,
    paid             numeric(15,5) DEFAULT 0,
    invoice          boolean       DEFAULT false,
    vendor_id        integer       NOT NULL REFERENCES vendor(id),
    taxincluded      boolean       DEFAULT false,
    terms            integer       DEFAULT 0,
    notes            text,
    intnotes         text,
    curr             char(3),
    ordnumber        varchar(255),
    ponumber         varchar(255),
    employee_id      integer       REFERENCES employee(id) ON DELETE SET NULL,
    department_id    integer       REFERENCES department(id) ON DELETE SET NULL,
    shippingpoint    text,
    shipvia          text,
    on_hold          boolean       DEFAULT false,
    reverse          boolean       DEFAULT false,
    approved         boolean       DEFAULT false,
    language_code    varchar(6),
    created_at       timestamptz   DEFAULT now(),
    updated_at       timestamptz   DEFAULT now()
);
CREATE INDEX ap_vendor_idx    ON ap(vendor_id);
CREATE INDEX ap_transdate_idx ON ap(transdate);
CREATE INDEX ap_invnumber_idx ON ap(invnumber);

-- ----------------------------------------------------------------------------
-- ar — Accounts Receivable (customer invoices)
-- ----------------------------------------------------------------------------
CREATE TABLE ar (
    id               serial        PRIMARY KEY,
    invnumber        varchar(255),
    transdate        date          NOT NULL DEFAULT current_date,
    duedate          date,
    datepaid         date,
    amount           numeric(15,5) DEFAULT 0,
    netamount        numeric(15,5) DEFAULT 0,
    paid             numeric(15,5) DEFAULT 0,
    invoice          boolean       DEFAULT false,
    customer_id      integer       NOT NULL REFERENCES customer(id),
    taxincluded      boolean       DEFAULT false,
    terms            integer       DEFAULT 0,
    notes            text,
    intnotes         text,
    curr             char(3),
    ordnumber        varchar(255),
    ponumber         varchar(255),
    employee_id      integer       REFERENCES employee(id) ON DELETE SET NULL,
    department_id    integer       REFERENCES department(id) ON DELETE SET NULL,
    shippingpoint    text,
    shipvia          text,
    on_hold          boolean       DEFAULT false,
    reverse          boolean       DEFAULT false,
    approved         boolean       DEFAULT false,
    language_code    varchar(6),
    created_at       timestamptz   DEFAULT now(),
    updated_at       timestamptz   DEFAULT now()
);
CREATE INDEX ar_customer_idx  ON ar(customer_id);
CREATE INDEX ar_transdate_idx ON ar(transdate);
CREATE INDEX ar_invnumber_idx ON ar(invnumber);

-- ----------------------------------------------------------------------------
-- invoice — line items for both AP and AR transactions
-- ----------------------------------------------------------------------------
CREATE TABLE invoice (
    id           serial        PRIMARY KEY,
    trans_id     integer       NOT NULL,
    parts_id     integer       REFERENCES parts(id) ON DELETE SET NULL,
    description  text,
    qty          numeric(15,5) DEFAULT 0,
    allocated    numeric(15,5) DEFAULT 0,
    sellprice    numeric(15,5) DEFAULT 0,
    fxsellprice  numeric(15,5) DEFAULT 0,
    discount     numeric(15,5) DEFAULT 0,
    assemblyitem boolean       DEFAULT false,
    unit         varchar(35),
    deliverydate date,
    project_id   integer,
    serialnumber text,
    base_qty     numeric(15,5) DEFAULT 0,
    itemnotes    text,
    taxaccounts  text
);
CREATE INDEX invoice_trans_idx ON invoice(trans_id);
CREATE INDEX invoice_parts_idx ON invoice(parts_id);

-- ----------------------------------------------------------------------------
-- acc_trans — GL transaction lines (the actual debit/credit entries)
-- trans_id links to gl.id, ap.id, or ar.id depending on context
-- Positive amount = debit for assets/expenses, credit for liabilities/income
-- ----------------------------------------------------------------------------
CREATE TABLE acc_trans (
    id             serial        PRIMARY KEY,
    trans_id       integer       NOT NULL,
    chart_id       integer       NOT NULL REFERENCES chart(id),
    amount         numeric(15,5) NOT NULL DEFAULT 0,
    transdate      date          NOT NULL DEFAULT current_date,
    source         varchar(255),
    cleared        boolean       DEFAULT false,
    fx_transaction boolean       DEFAULT false,
    memo           text,
    invoice_id     integer       REFERENCES invoice(id) ON DELETE SET NULL,
    entry_id       integer,
    created_at     timestamptz   DEFAULT now()
);
CREATE INDEX acc_trans_trans_idx  ON acc_trans(trans_id);
CREATE INDEX acc_trans_chart_idx  ON acc_trans(chart_id);
CREATE INDEX acc_trans_date_idx   ON acc_trans(transdate);
CREATE INDEX acc_trans_cleared_idx ON acc_trans(cleared);

-- ----------------------------------------------------------------------------
-- oe — Order Entry (sales orders and purchase orders)
-- ----------------------------------------------------------------------------
CREATE TABLE oe (
    id               serial        PRIMARY KEY,
    ordnumber        varchar(255),
    transdate        date          DEFAULT current_date,
    vendor_id        integer       REFERENCES vendor(id) ON DELETE SET NULL,
    customer_id      integer       REFERENCES customer(id) ON DELETE SET NULL,
    amount           numeric(15,5) DEFAULT 0,
    netamount        numeric(15,5) DEFAULT 0,
    reqdate          date,
    taxincluded      boolean       DEFAULT false,
    shippingpoint    text,
    notes            text,
    intnotes         text,
    curr             char(3),
    employee_id      integer       REFERENCES employee(id) ON DELETE SET NULL,
    closed           boolean       DEFAULT false,
    quotation        boolean       DEFAULT false,
    quonumber        varchar(255),
    department_id    integer       REFERENCES department(id) ON DELETE SET NULL,
    ponumber         varchar(255),
    terms            integer       DEFAULT 0,
    shipvia          text,
    language_code    varchar(6),
    shipdate         date,
    shipped          boolean       DEFAULT false,
    waybill          text,
    oe_class_id      integer,
    created_at       timestamptz   DEFAULT now(),
    updated_at       timestamptz   DEFAULT now()
);
CREATE INDEX oe_transdate_idx ON oe(transdate);
CREATE INDEX oe_customer_idx  ON oe(customer_id);
CREATE INDEX oe_vendor_idx    ON oe(vendor_id);

-- ----------------------------------------------------------------------------
-- orderitems — line items for OE (orders)
-- ----------------------------------------------------------------------------
CREATE TABLE orderitems (
    id           serial        PRIMARY KEY,
    trans_id     integer       NOT NULL REFERENCES oe(id) ON DELETE CASCADE,
    parts_id     integer       REFERENCES parts(id) ON DELETE SET NULL,
    description  text,
    qty          numeric(15,5) DEFAULT 0,
    sellprice    numeric(15,5) DEFAULT 0,
    discount     numeric(15,5) DEFAULT 0,
    unit         varchar(35),
    project_id   integer,
    serialnumber text,
    reqdate      date,
    ship         numeric(15,5) DEFAULT 0,
    base_qty     numeric(15,5) DEFAULT 0,
    itemnotes    text,
    taxaccounts  text
);
CREATE INDEX orderitems_trans_idx ON orderitems(trans_id);
CREATE INDEX orderitems_parts_idx ON orderitems(parts_id);

-- ----------------------------------------------------------------------------
-- warehouse — storage locations / bins
-- ----------------------------------------------------------------------------
CREATE TABLE warehouse (
    id           serial       PRIMARY KEY,
    description  varchar(255) NOT NULL,
    address1     varchar(255),
    city         varchar(100),
    notes        text
);

-- ----------------------------------------------------------------------------
-- inventory — stock movement log
-- ----------------------------------------------------------------------------
CREATE TABLE inventory (
    id              serial        PRIMARY KEY,
    warehouse_id    integer       REFERENCES warehouse(id) ON DELETE SET NULL,
    parts_id        integer       NOT NULL REFERENCES parts(id) ON DELETE CASCADE,
    trans_id        integer,
    orderitems_id   integer,
    qty             numeric(15,5) DEFAULT 0,
    shippingdate    date,
    employee_id     integer       REFERENCES employee(id) ON DELETE SET NULL,
    entry_date      timestamptz   DEFAULT now()
);
CREATE INDEX inventory_parts_idx     ON inventory(parts_id);
CREATE INDEX inventory_warehouse_idx ON inventory(warehouse_id);
CREATE INDEX inventory_trans_idx     ON inventory(trans_id);

-- ----------------------------------------------------------------------------
-- project — project tracking for GL entries and job costing
-- ----------------------------------------------------------------------------
CREATE TABLE project (
    id            serial        PRIMARY KEY,
    projectnumber varchar(255)  NOT NULL,
    description   text,
    startdate     date,
    enddate       date,
    parts_id      integer       REFERENCES parts(id) ON DELETE SET NULL,
    production    numeric(15,5) DEFAULT 0,
    allocated     numeric(15,5) DEFAULT 0,
    completed     boolean       DEFAULT false,
    customer_id   integer       REFERENCES customer(id) ON DELETE SET NULL,
    created_at    timestamptz   DEFAULT now()
);
CREATE INDEX project_number_idx ON project(projectnumber);

-- ============================================================================
-- DEFAULT SEED DATA (Canadian jurisdiction — override at provisioning time)
-- ============================================================================

INSERT INTO taxmodule (taxmodulename) VALUES ('Simple');

INSERT INTO defaults (setting_key, value) VALUES
    ('curr',                 'CAD'),
    ('weightunit',           'kg'),
    ('precision',            '2'),
    ('jurisdiction',         'CA'),
    ('tax_name',             'GST/HST'),
    ('tax_number_label',     'Business Number / GST#'),
    ('tax_rate_gst',         '0.05'),
    ('tax_rate_hst_on',      '0.13'),
    ('tax_rate_hst_bc',      '0.12'),
    ('tax_rate_pst_bc',      '0.07'),
    ('glnumber',             '1'),
    ('apnumber',             '1'),
    ('arnumber',             '1'),
    ('sonumber',             '1'),
    ('ponumber',             '1'),
    ('version',              '1.0'),
    ('businessnumber',       ''),
    ('company',              ''),
    ('address',              ''),
    ('city',                 ''),
    ('state',                ''),
    ('zipcode',              ''),
    ('country',              'Canada'),
    ('email',                ''),
    ('phone',                ''),
    ('fax',                  ''),
    ('website',              '');

-- Default Chart of Accounts (Canadian standard, 4-digit)
INSERT INTO chart (accno, description, charttype, category, link) VALUES
    ('1000', 'Cash / Chequing Account',           'A', 'A', 'AP_paid:AR_paid'),
    ('1005', 'Savings Account',                   'A', 'A', 'AP_paid:AR_paid'),
    ('1010', 'PayPal Account',                    'A', 'A', 'AP_paid:AR_paid'),
    ('1011', 'Stripe Account',                    'A', 'A', 'AR_paid'),
    ('1012', 'Square Account',                    'A', 'A', 'AR_paid'),
    ('1029', 'Prepaid Vendor Balances',            'A', 'A', 'AP_paid'),
    ('1100', 'Accounts Receivable',               'A', 'A', 'AR'),
    ('1200', 'Inventory Asset',                   'A', 'A', 'IC'),
    ('1300', 'Prepaid Expenses',                  'A', 'A', ''),
    ('1310', 'GST/HST Receivable (ITC)',           'A', 'A', 'AR_tax:AP_tax'),
    ('1500', 'Fixed Assets',                      'A', 'A', ''),
    ('2000', 'Accounts Payable',                  'A', 'L', 'AP'),
    ('2100', 'GST/HST Payable',                   'A', 'L', 'AR_tax'),
    ('2110', 'PST Payable',                       'A', 'L', ''),
    ('2200', 'Accrued Liabilities',               'A', 'L', ''),
    ('2300', 'Credit Card Payable — Visa',         'A', 'L', ''),
    ('2310', 'Credit Card Payable — MasterCard',   'A', 'L', ''),
    ('2320', 'Credit Card Payable — Amex',         'A', 'L', ''),
    ('3000', 'Owner''s Equity',                   'A', 'Q', ''),
    ('3100', 'Retained Earnings',                 'A', 'Q', ''),
    ('4000', 'Sales Revenue',                     'A', 'I', 'AR'),
    ('4100', 'Sales Returns & Allowances',         'A', 'I', 'AR'),
    ('4200', 'Service Revenue',                   'A', 'I', 'AR'),
    ('4210', '3D Print Sales',                    'A', 'I', 'AR'),
    ('4215', '3D Print Service Revenue',          'A', 'I', 'AR'),
    ('4220', 'Honey & Apiary Sales',              'A', 'I', 'AR'),
    ('4230', 'Craft & Handmade Sales',            'A', 'I', 'AR'),
    ('4250', 'Developer / IT Services Revenue',   'A', 'I', 'AR'),
    ('4260', 'Developer Services — GST/HST Collected', 'A', 'L', 'AR_tax'),
    ('4900', 'Other Income',                      'A', 'I', 'AR'),
    ('5000', 'Cost of Goods Sold',                'A', 'E', 'IC_cogs'),
    ('5100', 'Purchases',                         'A', 'E', 'AP'),
    ('5200', 'Purchase Discounts',                'A', 'E', 'AP'),
    ('6000', 'General & Administrative',          'A', 'E', 'AP'),
    ('6100', 'Wages & Salaries',                  'A', 'E', ''),
    ('6200', 'Supplies Expense',                  'A', 'E', 'AP'),
    ('6210', '3D Print Filament & Materials',     'A', 'E', 'AP'),
    ('6215', '3D Printer Equipment Lease',        'A', 'E', 'AP'),
    ('6216', '3D Printer Electricity & Power',    'A', 'E', 'AP'),
    ('6220', 'Apiary Supplies',                   'A', 'E', 'AP'),
    ('6230', 'Garden & Growing Supplies',         'A', 'E', 'AP'),
    ('6300', 'Equipment Expense',                 'A', 'E', 'AP'),
    ('6310', 'Taxes Paid (GST/PST/HST)',           'A', 'E', ''),
    ('6400', 'Shipping & Postage',                'A', 'E', 'AP'),
    ('6500', 'Depreciation Expense',              'A', 'E', ''),
    ('6510', '3D Printer Depreciation',           'A', 'E', ''),
    ('6600', 'Domain Registration & Renewals',    'A', 'E', 'AP'),
    ('6610', 'Web Hosting Expense',               'A', 'E', 'AP'),
    ('6620', 'SSL Certificates',                  'A', 'E', 'AP'),
    ('6700', 'Software Subscriptions',            'A', 'E', 'AP'),
    ('6710', 'Bank & Payment Processing Fees',    'A', 'E', 'AP'),
    ('6720', 'PayPal / Stripe Convenience Fees',  'A', 'E', 'AP'),
    ('6900', 'Other Expenses',                    'A', 'E', 'AP');

-- Link tax rate to GST/HST Receivable (ITC) account
INSERT INTO tax (chart_id, rate, taxnumber, taxmodule_id)
    SELECT id, 0.05, 'GST', 1 FROM chart WHERE accno = '1310';

-- Default warehouse
INSERT INTO warehouse (description) VALUES ('Main Warehouse');

-- Default payment terms
INSERT INTO payment (description, terms, net) VALUES
    ('Net 30', 0, 30),
    ('Net 15', 0, 15),
    ('Due on Receipt', 0, 0),
    ('2/10 Net 30', 2, 30);
