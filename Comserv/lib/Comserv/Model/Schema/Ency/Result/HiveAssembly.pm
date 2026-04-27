package Comserv::Model::Schema::Ency::Result::HiveAssembly;
use base 'DBIx::Class::Core';

__PACKAGE__->table('hive_assemblies');

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    configuration_id => {
        data_type   => 'integer',
        is_nullable => 0,
        comment     => 'FK → hive_configurations — blueprint used for this assembly',
    },
    hive_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → hives — hive built from this assembly (NULL if not yet deployed)',
    },
    assembly_date => {
        data_type   => 'date',
        is_nullable => 0,
        comment     => 'Date the assembly was completed',
    },
    assembled_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Username of person who assembled the hive',
    },
    is_active => {
        data_type     => 'boolean',
        default_value => 1,
        comment       => 'Whether this assembly is currently in use',
    },
    decommission_date => {
        data_type   => 'date',
        is_nullable => 1,
        comment     => 'Date the assembly was decommissioned or repurposed',
    },
    decommission_reason => {
        data_type   => 'varchar',
        size        => 200,
        is_nullable => 1,
    },
    inventory_item_id => {
        data_type   => 'integer',
        is_nullable => 1,
        comment     => 'FK → inventory_items — inventory record for this physical assembled hive unit',
    },
    notes => {
        data_type   => 'text',
        is_nullable => 1,
    },
    created_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP',
    },
    updated_at => {
        data_type     => 'timestamp',
        default_value => \'CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
    },
    created_by => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');

# Relationships

__PACKAGE__->belongs_to(
    'configuration',
    'Comserv::Model::Schema::Ency::Result::HiveConfiguration',
    'configuration_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

__PACKAGE__->belongs_to(
    'hive',
    'Comserv::Model::Schema::Ency::Result::Hive',
    'hive_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

__PACKAGE__->belongs_to(
    'inventory_item',
    'Comserv::Model::Schema::Ency::Result::InventoryItem',
    'inventory_item_id',
    { is_deferrable => 1, on_delete => 'SET NULL', join_type => 'LEFT' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::HiveAssembly - Physical hive assembly records

=head1 DESCRIPTION

Represents a physical hive assembled according to a configuration blueprint.
Links the abstract configuration template to the actual physical hive deployed
in the yard.

DB table: hive_assemblies (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * configuration — the configuration used as the blueprint

=item * hive — the physical hive created from this assembly (nullable until deployed)

=back

=cut
