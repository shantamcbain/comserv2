package Comserv::Model::Schema::Ency::Result::Beekeeping::InspectionFeeding;
use base 'DBIx::Class::Core';

__PACKAGE__->table('inspection_feedings');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    inspection_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → inspections',
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inventory_items — the feed product used (e.g. Sugar Syrup 1:1, Pollen Patty)',
    },
    feed_amount => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Quantity of feed provided (e.g. 1L, 500g, 1kg)',
    },
    feeder_inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inventory_items — the feeder equipment used (e.g. Top Feeder, Boardman Feeder)',
    },
    concentration => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
        comment     => 'Syrup concentration if applicable (e.g. 1:1, 2:1)',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships

__PACKAGE__->belongs_to(
    'inspection',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::Inspection',
    'inspection_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'inventory_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'feeder_inventory_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'feeder_inventory_item_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::InspectionFeeding - Feeding records per inspection

=head1 DESCRIPTION

Records feeding activities performed during a hive inspection. Multiple feedings
can be recorded per inspection (e.g. syrup top-up and pollen substitute placed
at the same visit).

Feed products and feeder equipment are referenced from the inventory system via
inventory_item_id and feeder_inventory_item_id respectively — no local enums.

DB table: inspection_feedings (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * inspection — the inspection during which feeding occurred

=item * inventory_item — the feed product from inventory (e.g. Sugar Syrup 1:1, Pollen Patty)

=item * feeder_inventory_item — the feeder equipment from inventory (e.g. Top Feeder, Boardman)

=back

=cut
