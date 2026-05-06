package Comserv::Model::Schema::Ency::Result::Accounting::ConfigurationInventory;
use base 'DBIx::Class::Core';

__PACKAGE__->table('configuration_inventory');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    configuration_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → hive_configurations',
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → inventory_items — item required for this configuration',
    },
    quantity => {
        data_type     => 'integer',
        default_value => 1,
        comment       => 'Number of units required',
    },
    is_optional => {
        data_type     => 'boolean',
        default_value => 0,
        comment       => 'Whether this item is optional or required',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
        comment     => 'Notes on usage or substitutions',
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
);

__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint(
    unique_config_item => [qw/configuration_id inventory_item_id/],
);

# Relationships

__PACKAGE__->belongs_to(
    'configuration',
    'Comserv::Model::Schema::Ency::Result::Beekeeping::HiveConfiguration',
    'configuration_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'inventory_item',
    'Comserv::Model::Schema::Ency::Result::Accounting::InventoryItem',
    'inventory_item_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::ConfigurationInventory - Inventory requirements for a hive configuration

=head1 DESCRIPTION

Lists the inventory items required (or optionally recommended) to assemble a
given hive configuration. This is the explicit bill-of-materials for the
configuration when an InventoryItem BOM is not linked directly.

DB table: configuration_inventory (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * configuration — the parent hive configuration

=item * inventory_item — the required inventory item

=back

=cut
