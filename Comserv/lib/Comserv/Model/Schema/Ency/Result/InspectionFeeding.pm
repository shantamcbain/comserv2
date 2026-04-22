package Comserv::Model::Schema::Ency::Result::InspectionFeeding;
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
    feed_type => {
        data_type => 'enum',
        extra     => {
            list => [qw/
                sugar_syrup
                fondant
                candy_board
                pollen_substitute
                protein_patty
                dry_sugar
                honey
                other
            /]
        },
        is_nullable => 0,
        comment => 'Type of feed provided',
    },
    feed_amount => {
        data_type   => 'varchar',
        size        => 50,
        is_nullable => 1,
        comment     => 'Quantity of feed (e.g. 1L, 500g, 1kg)',
    },
    feeder_type => {
        data_type => 'enum',
        extra     => {
            list => [qw/top_feeder boardman entrance hive_top pail frame_feeder open_feeding/]
        },
        is_nullable => 1,
        comment => 'Type of feeder used',
    },
    concentration => {
        data_type   => 'varchar',
        size        => 20,
        is_nullable => 1,
        comment     => 'Syrup concentration (e.g. 1:1, 2:1)',
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
    'Comserv::Model::Schema::Ency::Result::Inspection',
    'inspection_id',
    { is_deferrable => 1, on_delete => 'CASCADE' }
);

1;

=head1 NAME

Comserv::Model::Schema::Ency::Result::InspectionFeeding - Feeding records per inspection

=head1 DESCRIPTION

Records feeding activities performed during a hive inspection. Multiple feed
types can be recorded per inspection (e.g. syrup top-up and pollen substitute
placed at the same visit).

DB table: inspection_feedings (new — created via /admin/schema_comparison)

=head1 RELATIONSHIPS

=over 4

=item * inspection — the inspection during which feeding occurred

=back

=cut
