package Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('coa_accounts');

# Chart of Accounts (COA) — individual account entries.
# Modeled on LedgerSMB's account table.
#
# Each InventoryItem links to 3-4 COA accounts:
#   inventory_accno_id → asset account for stock value  (e.g. 1200 Inventory)
#   income_accno_id    → income account when sold        (e.g. 4000 Sales)
#   expense_accno_id   → COGS/expense when consumed      (e.g. 5000 COGS)
#   returns_accno_id   → contra-income for returns       (e.g. 4100 Returns)
#
# PointLedger transactions link to 7000-series accounts.
# category: A=Asset  L=Liability  Q=Equity  I=Income  E=Expense

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    accno => {
        data_type   => 'varchar',
        size        => 30,
        is_nullable => 0,
        comment     => 'Account number e.g. 1200, 5000',
    },
    description => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    category => {
        data_type   => 'char',
        size        => 1,
        is_nullable => 0,
        comment     => 'A=Asset L=Liability Q=Equity I=Income E=Expense',
    },
    heading_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → coa_account_headings',
    },
    is_contra => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
        comment       => 'Contra account (e.g. accumulated depreciation, sales returns)',
    },
    is_tax => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    obsolete => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
        comment     => 'NULL = applies to all sites',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
    updated_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
        set_on_update => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(['accno']);

__PACKAGE__->belongs_to(
    'heading',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccountHeading',
    { 'foreign.id' => 'self.heading_id' },
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->has_many(
    'gl_lines',
    'Comserv::Model::Schema::Ency::Result::Accounting::GlEntryLine',
    { 'foreign.account_id' => 'self.id' }
);

__PACKAGE__->has_many(
    'inventory_stock_items',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.inventory_accno_id' => 'self.id' }
);

__PACKAGE__->has_many(
    'inventory_income_items',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.income_accno_id' => 'self.id' }
);

__PACKAGE__->has_many(
    'inventory_expense_items',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.expense_accno_id' => 'self.id' }
);

sub category_label {
    my $self = shift;
    my %labels = (A => 'Asset', L => 'Liability', Q => 'Equity', I => 'Income', E => 'Expense');
    return $labels{ $self->category } || $self->category;
}

sub display_name {
    my $self = shift;
    return $self->accno . ' — ' . $self->description;
}

sub balance {
    my $self = shift;
    my $total = $self->gl_lines->get_column('amount')->sum || 0;
    return $total;
}

1;
