package Comserv::Model::Schema::Ency::Result::Accounting::InventoryTransaction;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_transactions');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    item_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    location_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    transaction_type => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 0,
    },
    quantity => {
        data_type   => 'decimal',
        size        => [12, 3],
        is_nullable => 0,
    },
    unit_cost => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
    },
    reference_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    todo_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    performed_by => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 1,
    },
    transaction_date => {
        data_type     => 'datetime',
        is_nullable   => 0,
        set_on_create => 1,
    },
    created_at => {
        data_type     => 'datetime',
        is_nullable   => 1,
        set_on_create => 1,
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->belongs_to(
    'item' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

__PACKAGE__->belongs_to(
    'location' => 'Comserv::Model::Schema::Ency::Result::Accounting::InventoryLocation',
    { 'foreign.id' => 'self.location_id' },
    { join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'todo' => 'Comserv::Model::Schema::Ency::Result::Todo',
    { 'foreign.record_id' => 'self.todo_id' },
    { join_type => 'LEFT' }
);

sub total_value {
    my $self = shift;
    return ($self->quantity || 0) * ($self->unit_cost || 0);
}

1;
