package Comserv::Model::Schema::Ency::Result::InventoryConsignment;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_consignments');

# status: open | partially_settled | settled | returned
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    sitename => {
        data_type   => 'varchar',
        size        => 255,
        is_nullable => 0,
    },
    partner_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    reference_number => {
        data_type   => 'varchar',
        size        => 100,
        is_nullable => 1,
    },
    date_sent => {
        data_type   => 'date',
        is_nullable => 0,
    },
    status => {
        data_type     => 'varchar',
        size          => 50,
        is_nullable   => 0,
        default_value => 'open',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_by => {
        data_type   => 'varchar',
        size        => 255,
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

__PACKAGE__->belongs_to(
    'partner',
    'Comserv::Model::Schema::Ency::Result::InventoryConsignmentPartner',
    { 'foreign.id' => 'self.partner_id' }
);

__PACKAGE__->has_many(
    'lines',
    'Comserv::Model::Schema::Ency::Result::InventoryConsignmentLine',
    { 'foreign.consignment_id' => 'self.id' },
    { cascade_delete => 1 }
);

1;
