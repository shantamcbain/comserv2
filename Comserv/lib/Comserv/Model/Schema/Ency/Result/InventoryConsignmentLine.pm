package Comserv::Model::Schema::Ency::Result::InventoryConsignmentLine;
use strict;
use warnings;
use base 'DBIx::Class::Core';

__PACKAGE__->load_components('InflateColumn::DateTime', 'TimeStamp');
__PACKAGE__->table('inventory_consignment_lines');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
        is_nullable       => 0,
    },
    consignment_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    item_id => {
        data_type      => 'integer',
        is_nullable    => 0,
        is_foreign_key => 1,
    },
    quantity_sent => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 0,
    },
    quantity_sold => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 0,
        default_value => 0,
    },
    quantity_returned => {
        data_type     => 'decimal',
        size          => [10, 2],
        is_nullable   => 0,
        default_value => 0,
    },
    retail_price => {
        data_type   => 'decimal',
        size        => [10, 2],
        is_nullable => 1,
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

__PACKAGE__->belongs_to(
    'consignment',
    'Comserv::Model::Schema::Ency::Result::InventoryConsignment',
    { 'foreign.id' => 'self.consignment_id' }
);

__PACKAGE__->belongs_to(
    'item',
    'Comserv::Model::Schema::Ency::Result::InventoryItem',
    { 'foreign.id' => 'self.item_id' }
);

sub quantity_outstanding {
    my $self = shift;
    return $self->quantity_sent - $self->quantity_sold - $self->quantity_returned;
}

sub our_revenue {
    my ($self, $commission_pct) = @_;
    my $gross = ($self->quantity_sold || 0) * ($self->retail_price || 0);
    return $gross * (1 - ($commission_pct || 0) / 100);
}

sub commission_amount {
    my ($self, $commission_pct) = @_;
    my $gross = ($self->quantity_sold || 0) * ($self->retail_price || 0);
    return $gross * (($commission_pct || 0) / 100);
}

1;
