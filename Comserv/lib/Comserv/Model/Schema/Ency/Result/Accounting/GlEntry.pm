package Comserv::Model::Schema::Ency::Result::Accounting::GlEntry;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('gl_entries');

# General Ledger journal entry header.
# Modeled on LedgerSMB's journal_entry table.
#
# Every financial event (inventory movement, point transaction, sale, purchase)
# generates one GL entry.  The matching GlEntryLine rows form the double-entry
# pair whose amounts must sum to zero.
#
# entry_type values:
#   general    — manual GL adjustment
#   inventory  — stock receive/consume/adjust (linked via inventory_transactions.gl_entry_id)
#   point      — Point System earn/spend (linked via point_ledger.gl_entry_id)
#   sale       — future: sales invoice
#   purchase   — future: purchase invoice
#   adjustment — physical count correction

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    reference => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
        comment     => 'Invoice/journal number — unique per entry_type',
    },
    description => {
        data_type   => 'text',
        is_nullable => 1,
    },
    entry_type => {
        data_type     => 'varchar',
        size          => 30,
        is_nullable   => 0,
        default_value => 'general',
        comment       => 'general | inventory | point | sale | purchase | adjustment',
    },
    post_date => {
        data_type        => 'date',
        is_nullable      => 0,
        inflate_datetime => 0,
    },
    approved => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    is_template => {
        data_type     => 'tinyint',
        is_nullable   => 0,
        default_value => 0,
    },
    currency => {
        data_type     => 'char',
        size          => 3,
        is_nullable   => 0,
        default_value => 'CAD',
    },
    exchange_rate => {
        data_type     => 'decimal',
        size          => [12, 6],
        is_nullable   => 1,
        default_value => '1.000000',
    },
    functional_amount => {
        data_type     => 'decimal',
        size          => [12, 2],
        is_nullable   => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 0,
    },
    entered_by => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → users.id',
    },
    approved_by => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → users.id',
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
__PACKAGE__->add_unique_constraint(uq_gl_reference => [qw/reference entry_type/]);

__PACKAGE__->has_many(
    'lines',
    'Comserv::Model::Schema::Ency::Result::Accounting::GlEntryLine',
    { 'foreign.gl_entry_id' => 'self.id' },
    { cascade_delete => 1, order_by => 'sort_order' }
);

__PACKAGE__->has_many(
    'point_ledger_entries',
    'Comserv::Model::Schema::Ency::Result::Accounting::PointLedger',
    { 'foreign.gl_entry_id' => 'self.id' }
);

sub is_balanced {
    my $self = shift;
    my $total = $self->lines->get_column('amount')->sum || 0;
    return abs($total) < 0.0001;
}

sub debit_total {
    my $self = shift;
    return $self->lines->search({ amount => { '>' => 0 } })->get_column('amount')->sum || 0;
}

sub credit_total {
    my $self = shift;
    my $total = $self->lines->search({ amount => { '<' => 0 } })->get_column('amount')->sum || 0;
    return abs($total);
}

1;
