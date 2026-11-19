package Comserv::Model::Schema::Ency::Result::Accounting::InventoryRecurringInvoiceLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_recurring_invoice_lines');

# Line template for a recurring supplier invoice (INV-R1 #2190).
# Mirrors inventory_supplier_invoice_lines so a schedule can carry the same
# shape as the bill it generates: item (optional), description, quantity,
# unit cost, GL account and stock location.
#
# line_total is deliberately NOT stored: it is quantity * unit_cost, and a
# cached copy is the first thing to go stale when the feed price changes.
# RecurringInvoice::_line_total() computes it at generation time.

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    recurring_invoice_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    description => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    quantity => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => '1.0000',
    },
    unit_cost => {
        data_type     => 'decimal',
        size          => [12, 4],
        is_nullable   => 0,
        default_value => '0.0000',
    },
    account_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'CoA expense account for this line',
    },
    location_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'recurring_invoice',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryRecurringInvoice',
    { 'foreign.id' => 'self.recurring_invoice_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'account',
    'Comserv::Model::Schema::Ency::Result::Accounting::CoaAccount',
    { 'foreign.id' => 'self.account_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

__PACKAGE__->belongs_to(
    'location',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.id' => 'self.location_id' },
    { join_type => 'LEFT', on_delete => 'SET NULL' }
);

sub line_total {
    my $self = shift;
    my $qty  = $self->quantity  || 0;
    my $cost = $self->unit_cost || 0;
    return sprintf('%.2f', $qty * $cost);
}

1;
