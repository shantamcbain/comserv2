package Comserv::Model::Schema::Ency::Result::Beekeeping::ConfigurationBox;
use base 'DBIx::Class::Core';

__PACKAGE__->table('configuration_boxes');

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
    box_position => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'Position in stack: 1=bottom, ascending toward top',
    },
    box_type => {
        data_type => 'enum',
        extra     => {
            list => [qw/brood super honey deep medium shallow/]
        },
        default_value => 'brood',
    },
    box_size => {
        data_type => 'enum',
        extra     => {
            list => [qw/deep medium shallow/]
        },
        default_value => 'deep',
    },
    frame_count => {
        data_type     => 'integer',
        default_value => 10,
        comment       => 'Number of frames this box holds in the configuration',
    },
    purpose => {
        data_type => 'enum',
        extra     => {
            list => [qw/brood_nest honey_storage pollen_storage feeder split other/]
        },
        is_nullable => 1,
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inventory_items — defines the physical box type and its BOM (e.g. Deep Box 10-frame)',
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

__PACKAGE__->add_unique_constraint(
    unique_config_position => [qw/configuration_id box_position/],
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
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::ConfigurationBox - Box specifications within a hive configuration

=head1 DESCRIPTION

Defines the per-box details of a hive configuration — box type, size, position,
and intended purpose. One row per box in the configuration stack.

DB table: configuration_boxes (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * configuration — the parent hive configuration

=back

=cut
